import XCTest

@testable import ZenTerm

/// Unit tests for the pure OS-notification gate (ZEN-139). The gate decides whether an agent event
/// fires a macOS banner; it's extracted from the system singleton precisely so this truth table is
/// testable without touching `UNUserNotificationCenter`.
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
