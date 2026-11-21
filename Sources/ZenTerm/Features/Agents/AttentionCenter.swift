import Foundation

// Main-thread only.
final class AttentionCenter {
    static let shared = AttentionCenter()

    init() {}

    // Agents, never windows.
    private var blockedByWindow: [Int: Int] = [:]

    func update(windowID: Int, blockedCount: Int) {
        blockedByWindow[windowID] = blockedCount > 0 ? blockedCount : nil
    }

    func forget(windowID: Int) {
        blockedByWindow[windowID] = nil
    }

    func blockedCount(excluding windowID: Int) -> Int {
        blockedByWindow.filter { $0.key != windowID }.values.reduce(0, +)
    }
}
