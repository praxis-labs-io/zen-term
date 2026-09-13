import XCTest

@testable import ZenTerm

final class AgentNotifierGateTests: XCTestCase {
    func test_inactiveAndEnabled_fires() {
        XCTAssertTrue(AgentNotifier.shouldPushNotification(appActive: false, enabled: true))
    }

    func test_activeAndEnabled_doesNotFire() {
        XCTAssertFalse(AgentNotifier.shouldPushNotification(appActive: true, enabled: true))
    }

    func test_inactiveAndDisabled_doesNotFire() {
        XCTAssertFalse(AgentNotifier.shouldPushNotification(appActive: false, enabled: false))
    }

    func test_activeAndDisabled_doesNotFire() {
        XCTAssertFalse(AgentNotifier.shouldPushNotification(appActive: true, enabled: false))
    }
}
