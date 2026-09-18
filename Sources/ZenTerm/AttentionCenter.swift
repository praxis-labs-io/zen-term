import Foundation

struct WindowAttention: Equatable {
    let windowID: Int
    let state: SurfaceAttention
    let since: Date?
}

/// Which windows have something asking for you, and since when. It answers nothing else. Main-thread only.
final class AttentionCenter {
    static let shared = AttentionCenter()

    init() {}

    private var byWindow: [Int: WindowAttention] = [:]

    func update(windowID: Int, state: SurfaceAttention, since: Date?) {
        guard state != .idle else {
            byWindow[windowID] = nil
            return
        }
        byWindow[windowID] = WindowAttention(windowID: windowID, state: state, since: since)
    }

    func forget(windowID: Int) {
        byWindow[windowID] = nil
    }

    /// Oldest first, so the one that has waited longest reads first.
    var waiting: [WindowAttention] {
        byWindow.values.sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }
}
