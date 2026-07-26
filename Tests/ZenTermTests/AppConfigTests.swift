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

    /// Every post carries a change set, so an observer never has to fall back to `.all` on the
    /// normal path — the fallback is there for hand-posted notifications, not for `reload()`.
    func test_reload_carriesAChangeSet() {
        var carried: ConfigChange?
        let expectation = expectation(forNotification: .configDidChange, object: nil) { note in
            carried = note.userInfo?[ConfigChange.userInfoKey] as? ConfigChange
            return true
        }
        AppConfig.reload()
        wait(for: [expectation], timeout: 1)
        XCTAssertNotNil(carried, "reload() posted without a change set — every observer would do full work")
    }

    /// ⌘⌥R is the "make the app match my config" escape hatch. Re-reading a file that resolved to
    /// the same values diffs to nothing, so without the force flag the chord would become a no-op
    /// — it has to re-apply everything regardless of the diff.
    func test_forcedReload_broadcastsAll() {
        var carried: ConfigChange?
        let expectation = expectation(forNotification: .configDidChange, object: nil) { note in
            carried = note.userInfo?[ConfigChange.userInfoKey] as? ConfigChange
            return true
        }
        AppConfig.reload(force: true)
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(carried, .all)
    }

    /// The unforced path must NOT hand out `.all` for a reload that changed nothing, or the gate
    /// buys nothing on the Settings live-apply path it exists for.
    func test_unforcedReloadOfUnchangedConfig_broadcastsNothing() {
        AppConfig.reload()  // settle: `current` now matches the file

        var carried: ConfigChange?
        let expectation = expectation(forNotification: .configDidChange, object: nil) { note in
            carried = note.userInfo?[ConfigChange.userInfoKey] as? ConfigChange
            return true
        }
        AppConfig.reload()
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(carried, [], "a no-op reload still asked every observer to re-apply")
    }
}
