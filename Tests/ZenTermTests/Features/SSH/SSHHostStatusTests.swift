import XCTest

@testable import ZenTerm

final class SSHHostStatusTests: XCTestCase {
    func test_offline_takesTheIdleAgentInk() {
        XCTAssertEqual(SSHHostStatus.offline.ink, Theme.current.chrome.ink(.muted))
    }

    func test_online_isPositive() {
        XCTAssertEqual(SSHHostStatus.online.ink, Theme.current.chrome.positive.nsColor)
    }

    func test_connected_takesTheWorkingAgentInk() {
        XCTAssertEqual(SSHHostStatus.connected.ink, Theme.current.chrome.working.nsColor)
    }
}
