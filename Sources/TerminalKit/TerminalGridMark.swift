/// A cell held through output, scrolling and reflow. Releasing the mark stops the tracking.
public final class TerminalGridMark {
    public enum Place: Equatable {
        case at(TerminalGridPoint)
        /// The mark's screen is not the one showing, such as the primary screen under a full-screen program.
        case aside
        /// The scrollback dropped the cell, or the surface is gone. Never comes back.
        case gone
    }

    private let read: () -> Place
    private let release: () -> Void

    /// For a backend: `read` answers `place`, and `release` runs once when the mark is freed.
    public init(read: @escaping () -> Place, release: @escaping () -> Void) {
        self.read = read
        self.release = release
    }

    public var place: Place { read() }

    deinit { release() }
}
