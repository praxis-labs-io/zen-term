import XCTest

@testable import ZenTerm

final class SSHHostStatusCenterTests: XCTestCase {
    private let devbox = SSHHostID(alias: "devbox")
    private var posts = 0
    private var observer: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        observer = NotificationCenter.default.addObserver(
            forName: .sshHostStatusDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.posts += 1 }
        }
    }

    override func tearDown() {
        observer.map(NotificationCenter.default.removeObserver)
        super.tearDown()
    }

    func test_aHostNoProbeHasAnswered_readsOffline() {
        XCTAssertEqual(SSHHostStatusCenter().status(of: devbox), .offline)
    }

    func test_aReachableHost_readsOnline() {
        let center = SSHHostStatusCenter()

        center.setReachable(true, host: devbox)

        XCTAssertEqual(center.status(of: devbox), .online)
    }

    func test_aHostThatStopsAnswering_readsOffline() {
        let center = SSHHostStatusCenter()
        center.setReachable(true, host: devbox)

        center.setReachable(false, host: devbox)

        XCTAssertEqual(center.status(of: devbox), .offline)
    }

    func test_aConnection_winsOverTheProbe() {
        let center = SSHHostStatusCenter()
        center.setReachable(false, host: devbox)

        center.setConnected(true, host: devbox)

        XCTAssertEqual(center.status(of: devbox), .connected)
    }

    func test_aDroppedConnection_fallsBackToTheLastProbe() {
        let center = SSHHostStatusCenter()
        center.setConnected(true, host: devbox)
        center.setReachable(false, host: devbox)

        center.setConnected(false, host: devbox)

        XCTAssertEqual(center.status(of: devbox), .offline)
    }

    func test_onlyARealChange_isAnnounced() {
        let center = SSHHostStatusCenter()

        center.setReachable(false, host: devbox)
        XCTAssertEqual(posts, 0, "already offline")

        center.setReachable(true, host: devbox)
        center.setReachable(true, host: devbox)
        XCTAssertEqual(posts, 1)

        center.setConnected(true, host: devbox)
        center.setReachable(false, host: devbox)
        XCTAssertEqual(posts, 2, "the probe cannot move a connected host")
    }
}
