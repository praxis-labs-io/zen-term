import PaneKit

/// Process-wide registry backing the nvim ⇄ ZenTerm navigator. Each live pane gets a
/// stable, globally-unique integer token (exported as `$ZEN_PANE`); `PaneID`/`TabID` are
/// only unique within a tab, so the token is the only key the nav socket can address a
/// pane by across every window.
///
/// It holds two things per token: the focus-move closure that routes a socket `focus`
/// command back to the pane's owning tab, and whether that pane is currently running nvim
/// (set over the socket, read by the key pass-through guard).
///
/// Main-thread only: every caller (the pane controllers, the key guard, and the socket
/// server — which hops decoded commands to `DispatchQueue.main`) touches it on the main
/// thread, so it needs no internal locking.
final class NavRegistry {
    /// The app-wide instance every caller uses. `init` is left internal only so tests can
    /// exercise a throwaway registry in isolation.
    static let shared = NavRegistry()
    init() {}

    private var nextToken = 1
    private var routes: [Int: (Direction) -> Void] = [:]
    private var vimTokens: Set<Int> = []

    /// The next token. Monotonic and never reused, so a stale socket message for a closed
    /// pane can never land on a later one that happened to reuse an id.
    func mintToken() -> Int {
        defer { nextToken += 1 }
        return nextToken
    }

    /// Register the pane's focus-move closure, invoked on a socket `focus` for this token.
    func register(token: Int, navigate: @escaping (Direction) -> Void) {
        routes[token] = navigate
    }

    /// Drop a pane's route and vim flag when it closes.
    func unregister(token: Int) {
        routes[token] = nil
        vimTokens.remove(token)
    }

    /// Route a socket `focus` command to the addressed pane's tab. No-op for an unknown
    /// token (a pane that has since closed).
    func route(focus token: Int, _ direction: Direction) {
        routes[token]?(direction)
    }

    /// Mark (or clear) the pane owning `token` as running nvim.
    func setVim(token: Int, _ on: Bool) {
        if on {
            vimTokens.insert(token)
        } else {
            vimTokens.remove(token)
        }
    }

    func isVim(token: Int) -> Bool { vimTokens.contains(token) }
}
