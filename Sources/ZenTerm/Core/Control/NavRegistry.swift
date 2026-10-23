import PaneKit

// Nav tokens (`$ZEN_PANE`) are unique across windows, unlike `PaneID`. Main-thread only.
final class NavRegistry {
    static let shared = NavRegistry()
    init() {}

    private var nextToken = 1
    private var routes: [Int: (Direction) -> Void] = [:]
    private var vimTokens: Set<Int> = []

    // Never reused, so a stale socket message for a closed pane cannot land on a later one.
    func mintToken() -> Int {
        defer { nextToken += 1 }
        return nextToken
    }

    func register(token: Int, navigate: @escaping (Direction) -> Void) {
        routes[token] = navigate
    }

    func unregister(token: Int) {
        routes[token] = nil
        vimTokens.remove(token)
    }

    func route(focus token: Int, _ direction: Direction) {
        routes[token]?(direction)
    }

    func setVim(token: Int, _ on: Bool) {
        if on {
            vimTokens.insert(token)
        } else {
            vimTokens.remove(token)
        }
    }

    func isVim(token: Int) -> Bool { vimTokens.contains(token) }
}
