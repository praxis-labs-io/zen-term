struct LaunchedPaneExits {
    // Tokens only grow, so the smallest held is the oldest exit.
    private static let kept = 64
    private var byToken: [Int: LaunchedPaneExit] = [:]

    mutating func record(_ exit: LaunchedPaneExit) {
        byToken[exit.token] = exit
        if byToken.count > Self.kept, let oldest = byToken.keys.min() { byToken[oldest] = nil }
    }

    func exit(of token: Int) -> LaunchedPaneExit? { byToken[token] }

    func latestExit(named name: String) -> LaunchedPaneExit? {
        byToken.values.filter { $0.record.name == name }.max { $0.token < $1.token }
    }

    func latestExit(named name: String, startedBy parent: Int) -> LaunchedPaneExit? {
        byToken.values.filter { $0.record.name == name && $0.record.parent == parent }.max { $0.token < $1.token }
    }
}
