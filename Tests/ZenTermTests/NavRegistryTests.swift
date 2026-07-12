import PaneKit
import XCTest

@testable import ZenTerm

@MainActor
final class NavRegistryTests: XCTestCase {
    // A fresh instance per test — `NavRegistry.shared` is process-wide, so tests use their
    // own to stay isolated.
    private func makeRegistry() -> NavRegistry { NavRegistry() }

    func test_mintToken_isMonotonic() {
        let registry = makeRegistry()
        let a = registry.mintToken()
        let b = registry.mintToken()
        let c = registry.mintToken()
        XCTAssertEqual([b, c], [a + 1, a + 2])
    }

    func test_route_invokesRegisteredClosure() {
        let registry = makeRegistry()
        let token = registry.mintToken()
        var received: Direction?
        registry.register(token: token) { received = $0 }

        registry.route(focus: token, .right)

        XCTAssertEqual(received, .right)
    }

    func test_route_unknownTokenIsNoOp() {
        let registry = makeRegistry()
        // No throw / no crash for a token that was never registered.
        registry.route(focus: 999, .left)
    }

    func test_unregister_stopsRouting() {
        let registry = makeRegistry()
        let token = registry.mintToken()
        var calls = 0
        registry.register(token: token) { _ in calls += 1 }

        registry.unregister(token: token)
        registry.route(focus: token, .up)

        XCTAssertEqual(calls, 0)
    }

    func test_setVim_togglesFlag() {
        let registry = makeRegistry()
        let token = registry.mintToken()
        XCTAssertFalse(registry.isVim(token: token))

        registry.setVim(token: token, true)
        XCTAssertTrue(registry.isVim(token: token))

        registry.setVim(token: token, false)
        XCTAssertFalse(registry.isVim(token: token))
    }

    func test_unregister_clearsVimFlag() {
        let registry = makeRegistry()
        let token = registry.mintToken()
        registry.setVim(token: token, true)

        registry.unregister(token: token)

        XCTAssertFalse(registry.isVim(token: token))
    }
}
