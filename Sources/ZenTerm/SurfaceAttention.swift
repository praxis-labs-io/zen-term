/// What one terminal surface is asking of you, ranked so every rollup is `max`.
enum SurfaceAttention: Int, Comparable, CaseIterable {
    case idle = 0, working = 1, completed = 2, waiting = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The loudest surface wins its tab, and the loudest tab wins the window.
    static func rollup(_ states: some Sequence<SurfaceAttention>) -> SurfaceAttention {
        states.reduce(.idle, max)
    }

    /// `working` renders as nothing: the tab bar colors two states and this is not one of them.
    var tabState: TabAttentionState {
        switch self {
        case .idle, .working: return .idle
        case .completed: return .completed
        case .waiting: return .waiting
        }
    }
}
