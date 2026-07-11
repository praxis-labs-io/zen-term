import AppKit

/// A theme-driven, keyboard-navigable slider for a bounded scalar (backdrop alpha, drawer
/// fractions). A focus stop in the 2D form flow — Left/Right nudge by `step`, Up/Down bubble to
/// move between rows, Tab reaches the row's reset icon. Draws a track, an accent fill, and a thumb,
/// plus a trailing value label. A shared form-control primitive (joins the ZEN-81 set).
final class Slider: NSView {
    private(set) var value: CGFloat
    var onChange: (CGFloat) -> Void
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onEsc: (() -> Void)?

    private let range: ClosedRange<CGFloat>
    private let step: CGFloat
    private let track = NSView()
    private let fill = NSView()
    private let thumb = NSView()
    private let valueLabel = NSTextField(labelWithString: "")
    private var isFocused = false { didSet { restyle() } }

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 14

    /// Pure: clamp to `range`, then quantize to the nearest `step` offset from `range.lowerBound`.
    static func snap(_ value: CGFloat, range: ClosedRange<CGFloat>, step: CGFloat) -> CGFloat {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let steps = ((clamped - range.lowerBound) / step).rounded()
        let snapped = range.lowerBound + steps * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// Pure: move `value` by `steps` grid steps, clamped/quantized.
    static func nudged(_ value: CGFloat, steps: Int, range: ClosedRange<CGFloat>, step: CGFloat) -> CGFloat {
        snap(value + CGFloat(steps) * step, range: range, step: step)
    }

    init(value: CGFloat, range: ClosedRange<CGFloat>, step: CGFloat, onChange: @escaping (CGFloat) -> Void) {
        self.range = range
        self.step = step
        self.onChange = onChange
        self.value = Slider.snap(value, range: range, step: step)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        for view in [track, fill, thumb] {
            view.wantsLayer = true
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        track.layer?.cornerRadius = trackHeight / 2
        fill.layer?.cornerRadius = trackHeight / 2
        thumb.layer?.cornerRadius = thumbSize / 2

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 40),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -10),
            track.centerYAnchor.constraint(equalTo: centerYAnchor),
            track.heightAnchor.constraint(equalToConstant: trackHeight),
            thumb.widthAnchor.constraint(equalToConstant: thumbSize),
            thumb.heightAnchor.constraint(equalToConstant: thumbSize),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setValue(_ newValue: CGFloat) {
        value = Slider.snap(newValue, range: range, step: step)
        restyle()
    }

    override func layout() {
        super.layout()
        // Position the fill + thumb along the track for the current value.
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let usable = track.frame.width - thumbSize
        let x = track.frame.minX + thumbSize / 2 + max(0, min(1, fraction)) * usable
        fill.frame = NSRect(x: track.frame.minX, y: track.frame.minY, width: x - track.frame.minX, height: trackHeight)
        thumb.frame = NSRect(x: x - thumbSize / 2, y: (bounds.height - thumbSize) / 2, width: thumbSize, height: thumbSize)
    }

    // MARK: keyboard

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: apply(Slider.nudged(value, steps: -1, range: range, step: step))  // left
        case 124: apply(Slider.nudged(value, steps: 1, range: range, step: step))  // right
        case 126: onArrowUp?()  // up
        case 125: onArrowDown?()  // down
        case 48: event.modifierFlags.contains(.shift) ? onBacktab?() : onTab?()  // ⇧tab / tab
        case 53 where onEsc != nil: onEsc?()  // esc
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) { drag(event) }
    override func mouseDragged(with event: NSEvent) { drag(event) }

    private func drag(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        let usable = track.frame.width - thumbSize
        guard usable > 0 else { return }
        let fraction = (local.x - track.frame.minX - thumbSize / 2) / usable
        apply(Slider.snap(range.lowerBound + fraction * (range.upperBound - range.lowerBound), range: range, step: step))
    }

    private func apply(_ newValue: CGFloat) {
        guard newValue != value else { return }
        value = newValue
        restyle()
        onChange(value)
    }

    private func restyle() {
        let chrome = Theme.current.chrome
        track.layer?.backgroundColor = chrome.ink(alpha: 0.12).cgColor
        fill.layer?.backgroundColor = chrome.accent.nsColor.cgColor
        thumb.layer?.backgroundColor = chrome.accent.nsColor.cgColor
        thumb.layer?.borderWidth = isFocused ? 3 : 0
        thumb.layer?.borderColor = isFocused ? chrome.accent.nsColor.withAlphaComponent(0.35).cgColor : nil
        valueLabel.stringValue = LayoutFormat.number(value)
        valueLabel.textColor = chrome.muted.nsColor
        needsLayout = true
    }
}
