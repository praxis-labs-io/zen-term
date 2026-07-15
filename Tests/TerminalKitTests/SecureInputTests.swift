import XCTest

@testable import TerminalKit

final class SecureInputTests: XCTestCase {
    /// A throwaway object whose identity stands in for a surface. Held strongly by the test so
    /// its `ObjectIdentifier` can't collide with a later allocation at the same address.
    private final class Surface {}

    private func makeManager() -> (manager: SecureInput, enables: () -> Int, disables: () -> Int) {
        let manager = SecureInput()
        var enables = 0
        var disables = 0
        manager.isActiveHook = { true }
        manager.enableHook = {
            enables += 1
            return noErr
        }
        manager.disableHook = {
            disables += 1
            return noErr
        }
        return (manager, { enables }, { disables })
    }

    func test_focusedWantEngagesOnce() {
        let (manager, enables, disables) = makeManager()
        let surface = Surface()
        manager.setScoped(ObjectIdentifier(surface), focused: true)
        XCTAssertEqual(enables(), 1)
        // Re-asserting the same focused desire must not double-engage.
        manager.setScoped(ObjectIdentifier(surface), focused: true)
        XCTAssertEqual(enables(), 1)
        XCTAssertEqual(disables(), 0)
    }

    func test_losingFocusReleases() {
        let (manager, _, disables) = makeManager()
        let surface = Surface()
        manager.setScoped(ObjectIdentifier(surface), focused: true)
        manager.setScoped(ObjectIdentifier(surface), focused: false)
        XCTAssertEqual(disables(), 1)
    }

    func test_removeScopedReleases() {
        let (manager, _, disables) = makeManager()
        let surface = Surface()
        manager.setScoped(ObjectIdentifier(surface), focused: true)
        manager.removeScoped(ObjectIdentifier(surface))
        XCTAssertEqual(disables(), 1)
    }

    func test_lockHeldWhileAnyFocusedSurfaceWantsIt() {
        let (manager, enables, disables) = makeManager()
        let first = Surface()
        let second = Surface()
        manager.setScoped(ObjectIdentifier(first), focused: true)
        manager.setScoped(ObjectIdentifier(second), focused: true)
        XCTAssertEqual(enables(), 1)  // engaged once, not per surface
        // One losing focus keeps the lock — the other still wants it.
        manager.setScoped(ObjectIdentifier(first), focused: false)
        XCTAssertEqual(disables(), 0)
        // The last one releasing drops it.
        manager.setScoped(ObjectIdentifier(second), focused: false)
        XCTAssertEqual(disables(), 1)
    }

    func test_inactiveAppNeverEngages() {
        let (manager, enables, _) = makeManager()
        manager.isActiveHook = { false }
        manager.setScoped(ObjectIdentifier(Surface()), focused: true)
        XCTAssertEqual(enables(), 0)
    }
}
