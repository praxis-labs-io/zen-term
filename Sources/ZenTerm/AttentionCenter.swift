import Foundation

struct WindowAttention: Equatable {
    let windowID: Int
    /// How many agents in that window are waiting, never how many windows.
    let count: Int
    let since: Date?
}

/// Which windows have an agent waiting on you, how many, and since when. It answers nothing else. Main-thread only.
final class AttentionCenter {
    static let shared = AttentionCenter()

    init() {}

    private var byWindow: [Int: WindowAttention] = [:]

    /// Only `waiting` counts. A working agent is not asking, and a finished command is not either.
    func update(windowID: Int, waitingCount: Int, since: Date?) {
        guard waitingCount > 0 else {
            byWindow[windowID] = nil
            return
        }
        byWindow[windowID] = WindowAttention(windowID: windowID, count: waitingCount, since: since)
    }

    func forget(windowID: Int) {
        byWindow[windowID] = nil
    }

    /// Every agent waiting outside this window, for the sidebar's one line.
    func waitingCount(excluding windowID: Int) -> Int {
        byWindow.values.filter { $0.windowID != windowID }.reduce(0) { $0 + $1.count }
    }

    /// Oldest first, so the one that has waited longest reads first.
    var waiting: [WindowAttention] {
        byWindow.values.sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }
}
