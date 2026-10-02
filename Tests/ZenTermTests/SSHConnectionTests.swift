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

    func test_theLiveWatch_makesTheFolder_andSeesTheSocketAppear() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-socket-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ssh", isDirectory: true).appendingPathComponent("1-ab")
        let ready = expectation(description: "ready")
        let appeared = expectation(description: "appeared")

        let cancel = SSHConnection.Watchers.live.awaitSocket(path, { ready.fulfill() }, { appeared.fulfill() })
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
