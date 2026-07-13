import XCTest

@testable import ZenTerm

/// End-to-end coverage of the one piece unit tests can't reach: the real `AF_UNIX` bind +
/// accept + read path (the `sockaddr_un` byte-copy in particular). Binds a temp socket,
/// connects a plain POSIX client, and asserts decoded commands are dispatched.
final class NavSocketServerTests: XCTestCase {
    func test_bindsAndDispatchesValidCommands_droppingGarbage() throws {
        let path = "/tmp/zt-nav-\(getpid()).sock"
        let focusReceived = expectation(description: "focus dispatched")
        let vimReceived = expectation(description: "setvim dispatched")
        var commands: [NavCommand] = []
        let server = NavSocketServer(path: path) { command in
            commands.append(command)
            if case .focus = command { focusReceived.fulfill() }
            if case .setVim = command { vimReceived.fulfill() }
        }
        server.start()
        defer { server.stop() }

        try sendLine(#"{"cmd":"focus","dir":"left","pane":5}"#, to: path)
        try sendLine(#"{"cmd":"setvim","pane":5,"vim":true}"#, to: path)
        try sendLine("garbage not json", to: path)  // must be dropped, never dispatched

        wait(for: [focusReceived, vimReceived], timeout: 3)
        XCTAssertEqual(commands.count, 2)  // the garbage line added nothing
        XCTAssertTrue(commands.contains(.focus(token: 5, dir: .left)))
        XCTAssertTrue(commands.contains(.setVim(token: 5, on: true)))
    }

    func test_persistentConnection_dispatchesEachLineBeforeClose() throws {
        // One connection, two lines sent with a wait between them and no close until the end:
        // proves each line dispatches as it arrives rather than waiting on EOF/timeout.
        let path = "/tmp/zt-nav-persist-\(getpid()).sock"
        let first = expectation(description: "first line")
        let second = expectation(description: "second line")
        var commands: [NavCommand] = []
        let server = NavSocketServer(path: path) { command in
            commands.append(command)
            if commands.count == 1 { first.fulfill() }
            if commands.count == 2 { second.fulfill() }
        }
        server.start()
        defer { server.stop() }

        let fd = try connectClient(to: path)
        defer { close(fd) }
        writeLine(#"{"cmd":"focus","dir":"up","pane":1}"#, to: fd)
        wait(for: [first], timeout: 3)
        writeLine(#"{"cmd":"focus","dir":"down","pane":2}"#, to: fd)
        wait(for: [second], timeout: 3)

        XCTAssertEqual(commands, [.focus(token: 1, dir: .up), .focus(token: 2, dir: .down)])
    }

    func test_stop_removesSocketFile() {
        let path = "/tmp/zt-nav-stop-\(getpid()).sock"
        let server = NavSocketServer(path: path) { _ in }
        server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        server.stop()
        // The listen fd closes on the source's queue; the socket file is unlinked in stop().
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func test_restart_rebindsAndStillDispatches() throws {
        // A stop→start cycle must rebind cleanly: the new listener owns its own fd (captured
        // per-source), so a prior source's cancel handler can't clobber it. If the fd were
        // shared, the restarted server would accept(-1) forever and this dispatch would time out.
        let path = "/tmp/zt-nav-restart-\(getpid()).sock"
        var commands: [NavCommand] = []
        let firstRound = expectation(description: "first round dispatched")
        let secondRound = expectation(description: "second round dispatched")
        let server = NavSocketServer(path: path) { command in
            commands.append(command)
            if commands.count == 1 { firstRound.fulfill() }
            if commands.count == 2 { secondRound.fulfill() }
        }

        server.start()
        defer { server.stop() }  // registered before the first throwing sendLine, so a throw can't leak the listener
        try sendLine(#"{"cmd":"focus","dir":"left","pane":1}"#, to: path)
        wait(for: [firstRound], timeout: 3)

        server.stop()
        server.start()
        try sendLine(#"{"cmd":"focus","dir":"right","pane":2}"#, to: path)
        wait(for: [secondRound], timeout: 3)

        XCTAssertEqual(commands, [.focus(token: 1, dir: .left), .focus(token: 2, dir: .right)])
    }

    func test_socketPath_isPerProcess() {
        // ZEN-116: a shared well-known path let a second ZenTerm instance steal (bind-over)
        // and then delete (quit-unlink) the first instance's socket. The path must embed
        // the pid so instances can never collide.
        XCTAssertTrue(NavSocketServer.socketPath.hasSuffix("nav.\(getpid()).sock"))
    }

    func test_secondServer_neverDisturbsFirst() throws {
        // The ZEN-116 mechanism, inverted: with per-instance paths, a second server's full
        // start→stop lifecycle must leave the first server's file AND dispatch intact.
        let pathA = "/tmp/zt-nav-a-\(getpid()).sock"
        let pathB = "/tmp/zt-nav-b-\(getpid()).sock"
        var commands: [NavCommand] = []
        let first = expectation(description: "before B")
        let second = expectation(description: "after B stopped")
        let serverA = NavSocketServer(path: pathA) { command in
            commands.append(command)
            if commands.count == 1 { first.fulfill() }
            if commands.count == 2 { second.fulfill() }
        }
        serverA.start()
        defer { serverA.stop() }
        try sendLine(#"{"cmd":"focus","dir":"left","pane":1}"#, to: pathA)
        wait(for: [first], timeout: 3)

        let serverB = NavSocketServer(path: pathB) { _ in }
        serverB.start()
        serverB.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: pathA))
        try sendLine(#"{"cmd":"focus","dir":"right","pane":2}"#, to: pathA)
        wait(for: [second], timeout: 3)
        XCTAssertEqual(commands, [.focus(token: 1, dir: .left), .focus(token: 2, dir: .right)])
    }

    func test_sweep_removesOnlySocketsWithNoListener() throws {
        let dir = NSTemporaryDirectory() + "zt-sweep-\(getpid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Live = a real listener answers the sweep's connect probe (the foreign-pid name
        // proves liveness comes from the probe, not pid arithmetic). Dead = a socket file
        // nobody answers — what a crashed instance leaves behind.
        let live = "\(dir)/nav.99999.sock"
        let liveServer = NavSocketServer(path: live) { _ in }
        liveServer.start()
        defer { liveServer.stop() }

        let deadPerPid = "\(dir)/nav.4242.sock"
        let deadLegacy = "\(dir)/nav.sock"  // a crashed pre-per-pid build's leftover
        let ownPid = "\(dir)/nav.\(getpid()).sock"  // skipped: probing it could race our own bind
        let unrelated = "\(dir)/notes.txt"
        for path in [deadPerPid, deadLegacy, ownPid, unrelated] {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        NavSocketServer.sweepStaleSockets(in: dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: deadPerPid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deadLegacy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownPid))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated))
    }

    /// Connect a throwaway `AF_UNIX` client, write one newline-terminated line, close.
    private func sendLine(_ line: String, to path: String) throws {
        let fd = try connectClient(to: path)
        defer { close(fd) }
        writeLine(line, to: fd)
    }

    /// Open and connect an `AF_UNIX` stream client to `path`, returning the socket fd.
    private func connectClient(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        XCTAssertLessThan(bytes.count, capacity)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, byte) in bytes.enumerated() { dst[i] = byte }
                dst[bytes.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0, "connect failed, errno=\(errno)")
        return fd
    }

    /// Write one newline-terminated line to a connected client fd.
    private func writeLine(_ line: String, to fd: Int32) {
        let payload = Array((line + "\n").utf8)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
