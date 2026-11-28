import AppKit

final class ToggleSwitch: ControlView, ThemeReapplying {
    private(set) var isOn: Bool
    var onChange: (Bool) -> Void
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled {
                setHovered(false)
                isPressed = false
                if hasKeyboardFocus { window?.makeFirstResponder(nil) }
            }
            window?.invalidateCursorRects(for: self)
            restyle()
        }
    }

    private static let trackHeight = ChromeMetrics.Height.xs
    private static let trackWidth = ChromeMetrics.Height.lg
    private static let knobInset = ChromeMetrics.Spacing.s2
    private let knob = CALayer()
    private var isPressed = false

    init(isOn: Bool = false, onChange: @escaping (Bool) -> Void) {
        self.isOn = isOn
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = ChromeMetrics.Radius.capsule(Self.trackHeight)
        let knobSide = Self.trackHeight - Self.knobInset * 2
        knob.bounds = CGRect(x: 0, y: 0, width: knobSide, height: knobSide)
        knob.cornerRadius = ChromeMetrics.Radius.capsule(knobSide)
        layer?.addSublayer(knob)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.trackWidth),
            heightAnchor.constraint(equalToConstant: Self.trackHeight),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.trackWidth, height: Self.trackHeight) }

    func setOn(_ on: Bool) {
        isOn = on
        restyle()
        placeKnob(animated: false)
    }

    func reapplyTheme() { restyle() }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func drawFocusRingMask() {}

    override func focusDidChange() { restyle() }

    override func hoverDidChange() { restyle() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knob.position = knobCenter
        CATransaction.commit()
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) { isPressed = isEnabled }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        guard isPressed, isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return super.keyDown(with: event) }
        switch KeyboardFocus.key(for: event) {
        case .activate where KeyboardFocus.isUnmodified(event): flip()
        case .left: onArrowLeft?()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityValue() -> Any? { NSNumber(value: isOn) }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        flip()
        return true
    }

    private func flip() {
        isOn.toggle()
        restyle()
        placeKnob(animated: window != nil)
        onChange(isOn)
    }

    private func restyle() {
        setAccessibilityEnabled(isEnabled)
        let chrome = Theme.current.chrome
        let track: NSColor
        let knobColor: NSColor
        if !isEnabled {
            track = chrome.fill(.rest)
            knobColor = chrome.ink(.faint)
        } else if isOn {
            track = chrome.accent.nsColor
            knobColor = chrome.onAccent.nsColor
        } else {
            track = chrome.fill(.active)
            knobColor = chrome.ink(showsHover ? .normal : .subtle)
        }
        easeFill(track)
        if knob.backgroundColor != knobColor.cgColor {
            Motion.ease(knob, keyPath: "backgroundColor", to: knobColor.cgColor)
        }
        showFocusRing(hasKeyboardFocus && isEnabled)
    }

    private var knobCenter: CGPoint {
        let radius = knob.bounds.width / 2
        let x = isOn ? bounds.width - Self.knobInset - radius : Self.knobInset + radius
        return CGPoint(x: x, y: bounds.midY)
    }

    private func placeKnob(animated: Bool) {
        let target = knobCenter
        guard animated else {
            knob.removeAnimation(forKey: "motion.position")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            knob.position = target
            CATransaction.commit()
            return
        }
        Motion.ease(knob, keyPath: "position", to: NSValue(point: target))
    }

    var knobCenterForTesting: CGPoint { knob.position }
    var knobFillForTesting: CGColor? { knob.backgroundColor }
    var trackFillForTesting: CGColor? { layer?.backgroundColor }
    var isKnobSlidingForTesting: Bool { knob.animation(forKey: "motion.position") != nil }

    #if DEBUG
        func forceFocusForGallery() { setKeyboardFocus(true) }
        func forceHoverForGallery() { setHovered(true) }
    #endif
}
