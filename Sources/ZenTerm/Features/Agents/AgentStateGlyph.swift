import AppKit

// An Agents row's state mark: a dot for blocked, done and idle, a spinner while working.
final class AgentStateGlyph: NSView {
    private static let size = NSSize(width: 14, height: 16)

    let dot = StateDot()
    private let spinner = Spinner()

    // The marks sit on their row's title line, so the row pins them rather than this slot.
    var marks: [NSView] { [dot, spinner] }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        spinner.role = \.working
        for mark in marks {
            mark.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mark)
            mark.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ state: AttentionTone) {
        dot.state = state.dot
        spinner.isHidden = state != .working
        spinner.isSpinning = state == .working
    }

    var isSpinning: Bool { !spinner.isHidden && spinner.isSpinning }
}
