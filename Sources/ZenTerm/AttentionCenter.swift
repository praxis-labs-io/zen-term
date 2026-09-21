import Foundation

extension Notification.Name {
    static let attentionCenterDidChange = Notification.Name("attentionCenterDidChange")
}

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

    /// Lists the window while `waitingCount` is above zero, and drops it at zero.
    func update(windowID: Int, waitingCount: Int, since: Date?) {
        let entry =
            waitingCount > 0
            ? WindowAttention(windowID: windowID, count: waitingCount, since: since) : nil
        set(windowID, entry)
    }

    func forget(windowID: Int) {
        set(windowID, nil)
    }

    // Only a real change announces itself, or two windows rendering each other would never settle.
    private func set(_ windowID: Int, _ entry: WindowAttention?) {
        guard byWindow[windowID] != entry else { return }
        byWindow[windowID] = entry
        NotificationCenter.default.post(name: .attentionCenterDidChange, object: windowID)
    }

    /// Every agent waiting outside this window.
    func waitingCount(excluding windowID: Int) -> Int {
        byWindow.values.filter { $0.windowID != windowID }.reduce(0) { $0 + $1.count }
    }

    /// How many other windows hold one, so the copy can choose window or windows.
    func waitingWindows(excluding windowID: Int) -> Int {
        byWindow.values.filter { $0.windowID != windowID }.count
    }

    /// Oldest first, so the one that has waited longest reads first. Ties resolve by window, never by luck.
    var waiting: [WindowAttention] {
        byWindow.values.sorted {
            let a = $0.since ?? .distantFuture
            let b = $1.since ?? .distantFuture
            return a == b ? $0.windowID < $1.windowID : a < b
        }
    }
}
