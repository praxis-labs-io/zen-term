import XCTest

@testable import ZenTerm

final class AppConfigTests: XCTestCase {
    /// `AppConfig.reload()` is the seam `.reloadConfig` routes through (`AppDelegate.route`
    /// calls it directly, app-level, alongside `.newWindow`): it re-resolves the config statics
    /// and broadcasts `.configDidChange` so every live observer (keymap, motion, backdrop tint,
    /// terminal surfaces) re-applies. This asserts the broadcast half of that contract.
    func test_reload_postsConfigDidChange() {
        let expectation = expectation(forNotification: .configDidChange, object: nil, handler: nil)
        AppConfig.reload()
        wait(for: [expectation], timeout: 1)
    }
}
