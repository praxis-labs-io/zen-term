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

    func test_stop_removesSocketFile() {
        let path = "/tmp/zt-nav-stop-\(getpid()).sock"
        let server = NavSocketServer(path: path) { _ in }
        server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Connect a throwaway `AF_UNIX` client, write one newline-terminated line, close.
    private func sendLine(_ line: String, to path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

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

        let payload = Array((line + "\n").utf8)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
