import TerminalKit
import XCTest

@testable import ZenTerm

final class SSHConnectionTests: XCTestCase {
    private let host = SSHHostID(name: "devbox")
    private var fake: FakeSSHWatchers!
    private var connection: SSHConnection!
    private var connectedChanges: [Bool] = []
    private var loginFailures = 0

    override func setUp() {
        super.setUp()
        GeneralConfig.setCurrentForTesting(.builtIn)
        fake = FakeSSHWatchers()
        connection = SSHConnection(
            host: host, controlPath: URL(fileURLWithPath: "/tmp/zt/1-ab"), watchers: fake.watchers)
        connection.onConnectedChange = { [weak self] in self?.connectedChanges.append($0) }
        connection.onLoginFailed = { [weak self] in self?.loginFailures += 1 }
    }

    private func surface(_ raw: Int) -> (RecordingSurface, SurfaceID) { (RecordingSurface(), SurfaceID(raw: raw)) }

    func test_theLoginStartsOnceItsFolderIsReady_andRunsSSH() {
        let (login, id) = surface(1)

        connection.start(login, id: id, env: ["A": "1"])
        XCTAssertEqual(login.startCount, 0)
        fake.ready?()

        XCTAssertEqual(login.startCount, 1)
        XCTAssertEqual(login.lastConfig?.command, "/usr/bin/ssh")
        XCTAssertEqual(login.lastConfig?.args.last, "devbox")
        XCTAssertEqual(login.lastConfig?.environment["A"], "1")
        XCTAssertEqual(connection.state, .connecting)
    }

    func test_everyOtherSurfaceWaitsWhileConnecting_thenStartsInOrderOnceConnected() {
        let (login, loginID) = surface(1)
        let (pane, paneID) = surface(2)
        let (drawer, drawerID) = surface(3)
        var order: [String] = []
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        connection.start(pane, id: paneID, env: [:])
        connection.start(drawer, id: drawerID, env: [:])

        XCTAssertEqual(pane.startCount, 0, "a pane started beside the login would prompt for the password too")
        XCTAssertEqual(drawer.startCount, 0)
        connection.onConnectedChange = { _ in order.append("reported") }
        fake.connect()

        XCTAssertEqual(pane.startCount, 1)
        XCTAssertEqual(drawer.startCount, 1)
        XCTAssertEqual(drawer.lastConfig?.command, "/usr/bin/ssh")
        XCTAssertEqual(connection.state, .connected)
        XCTAssertEqual(order, ["reported"])
    }

    func test_aSurfaceStartedOnceConnected_startsAtOnce() {
        let (login, loginID) = surface(1)
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        fake.connect()
        let (pane, paneID) = surface(2)

        connection.start(pane, id: paneID, env: [:])

        XCTAssertEqual(pane.startCount, 1)
        XCTAssertEqual(connectedChanges, [true])
    }

    func test_aLoginThatEndsBeforeTheSocket_failsAndTheWaitingNeverStart() {
        let (login, loginID) = surface(1)
        let (pane, paneID) = surface(2)
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        connection.start(pane, id: paneID, env: [:])

        connection.release([loginID])
        fake.connect()
        let (late, lateID) = surface(3)
        connection.start(late, id: lateID, env: [:])

        XCTAssertEqual(connection.state, .failed)
        XCTAssertEqual(loginFailures, 1)
        XCTAssertEqual(pane.startCount, 0)
        XCTAssertEqual(late.startCount, 0)
        XCTAssertEqual(fake.socketWatches, 1, "a failed host starts no second login until it is connected again")
        XCTAssertEqual(connectedChanges, [])
        XCTAssertEqual(fake.cancels, 1)
    }

    func test_aWaitingSurfaceReleasedBeforeTheConnection_neverStarts() {
        let (login, loginID) = surface(1)
        let (pane, paneID) = surface(2)
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        connection.start(pane, id: paneID, env: [:])

        connection.release([paneID])
        fake.connect()

        XCTAssertEqual(pane.startCount, 0)
        XCTAssertEqual(loginFailures, 0)
    }

    func test_whenTheMasterExits_theHostReadsDisconnected_andTheNextSurfaceLogsInAgain() {
        let (login, loginID) = surface(1)
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        fake.connect()

        fake.exited?()
        fake.answerBeforeLogin = .some(nil)
        let (pane, paneID) = surface(2)
        let (other, otherID) = surface(3)
        connection.start(pane, id: paneID, env: [:])
        connection.start(other, id: otherID, env: [:])
        fake.ready?()

        XCTAssertEqual(connectedChanges, [true, false])
        XCTAssertEqual(connection.state, .connecting)
        XCTAssertEqual(fake.socketWatches, 2)
        XCTAssertEqual(pane.startCount, 1)
        XCTAssertEqual(other.startCount, 0)
    }

    func test_shuttingDownAConnectedHost_reportsItDisconnected_andStopsWatching() {
        let (login, loginID) = surface(1)
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        fake.connect()

        connection.shutdown()
        fake.exited?()

        XCTAssertEqual(connectedChanges, [true, false])
        XCTAssertEqual(fake.exitCancels, 1)
    }

    func test_endingAConnectedHost_signalsTheMasterItWatched() {
        let (login, loginID) = surface(1)
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        fake.connect(pid: 42)

        connection.shutdown()
        connection.endMaster()

        XCTAssertEqual(fake.ended, [42])
    }

    func test_aMasterThatAlreadyExited_isNeverSignalled() {
        let (login, loginID) = surface(1)
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        fake.connect(pid: 42)
        fake.exited?()

        connection.shutdown()
        connection.endMaster()
        fake.found?(nil)

        XCTAssertEqual(fake.ended, [], "a pid freed by an exited master may belong to anything by now")
    }

    func test_aMasterThatCameUpMidConnect_isResolvedThenEnded() {
        let (login, loginID) = surface(1)
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        fake.appeared?()

        connection.shutdown()
        connection.endMaster()
        fake.found?(77)

        XCTAssertEqual(fake.ended, [77])
    }

    func test_endingTwice_signalsTheMasterOnce() {
        let (login, loginID) = surface(1)
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        fake.connect(pid: 42)

        connection.endMaster()
        connection.endMaster()

        XCTAssertEqual(fake.ended, [42])
    }

    private func spawn(_ executable: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func waitForExit(_ process: Process, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return !process.isRunning
    }

    private let livePath = URL(fileURLWithPath: "/tmp/zt-live/4242-abcdef01")

    private func sshNaming(_ controlPath: URL) throws -> Process {
        try spawn(
            SSHLaunch.executable,
            [
                "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ControlPath=\"\(controlPath.path)\"",
                "-o", "ProxyCommand=/bin/sleep 30", "zt-test.invalid",
            ])
    }

    func test_theLiveEnd_terminatesTheSSHHoldingThisControlPath() throws {
        let ssh = try sshNaming(livePath)
        defer { if ssh.isRunning { ssh.terminate() } }

        SSHConnection.Watchers.live.endMaster(ssh.processIdentifier, livePath)

        XCTAssertTrue(waitForExit(ssh, within: 2))
        XCTAssertEqual(ssh.isRunning ? nil : ssh.terminationReason, .uncaughtSignal)
    }

    func test_theLiveEnd_leavesAnSSHForAnotherControlPathRunning() throws {
        let ssh = try sshNaming(URL(fileURLWithPath: "/tmp/zt-live/9999-abcdef01"))
        defer { ssh.terminate() }

        SSHConnection.Watchers.live.endMaster(ssh.processIdentifier, livePath)

        XCTAssertFalse(waitForExit(ssh, within: 0.3), "a pid recycled by the user's own ssh must never be signalled")
    }

    func test_theLiveEnd_leavesAProcessThatIsNotSSHRunning() throws {
        let sleeper = try spawn("/bin/sh", ["-c", "sleep 30", livePath.path])
        defer { sleeper.terminate() }

        SSHConnection.Watchers.live.endMaster(sleeper.processIdentifier, livePath)

        XCTAssertFalse(waitForExit(sleeper, within: 0.3), "a recycled pid must never be signalled")
    }

    func test_aMasterAlreadyAnswering_connectsTheLoginWithoutWaitingForTheSocket() {
        fake.answerBeforeLogin = .some(42)
        let (login, loginID) = surface(1)

        connection.start(login, id: loginID, env: [:])

        XCTAssertEqual(connection.state, .connected)
        XCTAssertEqual(login.startCount, 1)
        XCTAssertEqual(fake.socketWatches, 0)
        XCTAssertEqual(connectedChanges, [true])
    }

    func test_aSocketNoMasterAnswersOn_isNotConnected_andTheWatchWaitsForTheRealOne() {
        let (login, loginID) = surface(1)
        let (pane, paneID) = surface(2)
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        connection.start(pane, id: paneID, env: [:])

        fake.appeared?()
        fake.found?(nil)

        XCTAssertEqual(connection.state, .connecting)
        XCTAssertEqual(connectedChanges, [])
        XCTAssertEqual(pane.startCount, 0)
        XCTAssertEqual(fake.socketWatches, 1, "the re-check waits")
        fake.runDelayed()
        XCTAssertEqual(fake.socketWatches, 2)
        fake.ready?()
        XCTAssertEqual(login.startCount, 1, "re-arming the watch must not launch the login twice")
        fake.connect()
        XCTAssertEqual(pane.startCount, 1)
        XCTAssertEqual(connectedChanges, [true])
    }

    func test_aSocketThatNeverAnswersAsAMaster_isNotRecheckedInATightLoop() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("1-ab")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        var resolves = 0
        var watchers = SSHConnection.Watchers.live
        watchers.resolveMaster = { _, _, found in
            resolves += 1
            found(nil)
        }
        let live = SSHConnection(host: host, controlPath: path, watchers: watchers)
        defer { live.shutdown() }
        let (login, loginID) = surface(1)

        live.start(login, id: loginID, env: [:])
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertLessThanOrEqual(resolves, 3, "a socket no master answers on must not spin ssh -O check")
    }

    func test_aSocketNoMasterEverAnswersOn_failsLikeALogin_afterAFewChecks() {
        let (login, loginID) = surface(1)
        let (pane, paneID) = surface(2)
        connection.start(login, id: loginID, env: [:])
        fake.ready?()
        connection.start(pane, id: paneID, env: [:])

        for _ in 0..<SSHConnection.checksBeforeGivingUp {
            fake.appeared?()
            fake.found?(nil)
            fake.runDelayed()
        }

        XCTAssertEqual(connection.state, .failed)
        XCTAssertEqual(loginFailures, 1)
        XCTAssertEqual(pane.startCount, 0)
        XCTAssertEqual(fake.socketWatches, SSHConnection.checksBeforeGivingUp, "no watch after giving up")
    }

    func test_aSocketFolderThatCannotBeWatched_failsTheConnectionLikeALogin() {
        let (login, loginID) = surface(1)
        let (pane, paneID) = surface(2)
        connection.start(login, id: loginID, env: [:])
        connection.start(pane, id: paneID, env: [:])

        fake.unwatchable?()

        XCTAssertEqual(connection.state, .failed)
        XCTAssertEqual(loginFailures, 1)
        XCTAssertEqual(login.startCount, 0)
        XCTAssertEqual(pane.startCount, 0)
    }

    func test_theLiveWatch_reportsAFolderItCannotMake() throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let path = blocker.appendingPathComponent("ssh", isDirectory: true).appendingPathComponent("1-ab")
        let unwatchable = expectation(description: "unwatchable")

        let cancel = SSHConnection.Watchers.live.awaitSocket(
            path, { XCTFail("nothing is watching, so the login must not start") }, {}, { unwatchable.fulfill() })
        defer { cancel() }

        wait(for: [unwatchable], timeout: 2)
    }

    private func socketFile(listening: Bool) throws -> (URL, Int32) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("zt-\(UUID().uuidString.prefix(8))")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (index, byte) in path.path.utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try XCTSkipIf(bound != 0, "couldn't bind a test socket")
        guard listening else {
            Darwin.close(fd)
            return (path, fd)
        }
        Darwin.listen(fd, 1)
        DispatchQueue.global().async {
            let client = Darwin.accept(fd, nil, nil)
            if client >= 0 { Darwin.close(client) }
        }
        return (path, fd)
    }

    func test_theLiveResolve_removesASocketNothingListensOn() throws {
        let (path, _) = try socketFile(listening: false)
        defer { unlink(path.path) }

        let pid = SSHConnection.Watchers.master(of: SSHHostID(name: "zt-test.invalid"), at: path)

        XCTAssertNil(pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "a refused socket is stale and must go")
    }

    func test_theLiveResolve_leavesASocketSomethingStillListensOn() throws {
        let (path, fd) = try socketFile(listening: true)
        defer {
            close(fd)
            unlink(path.path)
        }

        let pid = SSHConnection.Watchers.master(of: SSHHostID(name: "zt-test.invalid"), at: path)

        XCTAssertNil(pid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "a socket that still answers is never removed")
    }

    func test_theLiveWatch_makesTheFolder_andSeesTheSocketAppear() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-socket-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ssh", isDirectory: true).appendingPathComponent("1-ab")
        let ready = expectation(description: "ready")
        let appeared = expectation(description: "appeared")

        let cancel = SSHConnection.Watchers.live.awaitSocket(
            path, { ready.fulfill() }, { appeared.fulfill() }, { XCTFail("the folder can be watched") })
        defer { cancel() }
        wait(for: [ready], timeout: 2)
        var isFolder: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
        FileManager.default.createFile(atPath: path.path, contents: nil)

        wait(for: [appeared], timeout: 2)
    }
}
