import AppKit

// Fades a pane toward its own background while a float covers it.
final class PaneVeilView: NSView {
    private(set) var isRaised = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var color: NSColor = .clear { didSet { layer?.backgroundColor = color.cgColor } }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { layer?.cornerRadius = newValue }
    }

    // Frontmost over the terminal, so taking a hit would swallow every click, drag and scroll in the pane.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setRaised(_ raised: Bool, animated: Bool) {
        guard raised != isRaised || !animated else { return }
        isRaised = raised
        let opacity = raised ? Float(ChromeTheme.paneVeil) : 0
        guard animated else {
            layer?.removeAnimation(forKey: "motion.opacity")
            layer?.opacity = opacity
            return
        }
        Motion.fade(self, to: opacity)
    }
}
