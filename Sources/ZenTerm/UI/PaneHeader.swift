import AppKit

// The strip atop a terminal pane, drawer or float: its label, then its controls.
final class PaneHeader: ControlView, ThemeReapplying {
    struct Label: Equatable {
        var text: String
        // A path loses its front instead of its end, so the folder it names survives truncation.
        var isPath = false
    }

    enum Control: CaseIterable {
        case splitHorizontal, splitVertical, focusMode, minimize, close

        var symbol: String {
            switch self {
            case .splitHorizontal: return "rectangle.split.1x2"
            case .splitVertical: return "rectangle.split.2x1"
            case .focusMode: return "arrow.up.left.and.arrow.down.right"
            case .minimize: return "minus"
            case .close: return "xmark"
            }
        }

        var chord: KeyInterceptor.ReservedChord? {
            switch self {
            case .splitHorizontal: return .splitHorizontal
            case .splitVertical: return .splitVertical
            case .focusMode: return .toggleZoom
            case .close: return .closePane
            case .minimize: return nil
            }
        }

        var label: String {
            switch self {
            case .splitHorizontal: return "Split horizontally"
            case .splitVertical: return "Split vertically"
            case .focusMode: return "Focus mode"
            case .minimize: return "Minimize"
            case .close: return "Close"
            }
        }
    }

    var label: Label {
        didSet {
            guard label != oldValue else { return }
            applyLabel()
        }
    }

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            applyControlsShown(animated: true)
        }
    }

    var isZoomed = false {
        didSet { buttons[.focusMode]?.isActive = isZoomed }
    }

    // The label's capitals center on the strip, which a label's line box, descent and all, would not.
    private static var labelFont: NSFont { ChromeType.font(.small, weight: .medium) }

    private let controls: [Control]
    private let onControl: (Control) -> Void
    private let labelField = NSTextField(labelWithString: "")
    private let controlStack = NSStackView()
    private var buttons: [Control: IconButton] = [:]
    private var isCollapsed = false
    private var controlsShown = false

    init(label: Label, controls: [Control], onControl: @escaping (Control) -> Void) {
        self.label = label
        self.controls = controls
        self.onControl = onControl
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange), name: NSView.frameDidChangeNotification, object: self)

        labelField.makeSingleLine()
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        controlStack.orientation = .horizontal
        controlStack.spacing = ChromeMetrics.Spacing.s2
        controlStack.translatesAutoresizingMaskIntoConstraints = false
        controlStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        for control in controls {
            let button = IconButton(
                symbol: control.symbol,
                size: NSSize(width: ChromeMetrics.Height.xs, height: ChromeMetrics.Height.xs),
                pointSize: ChromeMetrics.Icon.xs, accessibilityLabel: control.label, restInk: .muted,
                onClick: { [weak self] in self?.onControl(control) })
            button.firesOnRelease = true
            buttons[control] = button
            controlStack.addArrangedSubview(button)
        }

        [labelField, controlStack].forEach(addSubview)
        let gap = ChromeMetrics.Spacing.s8
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.xs),
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.firstBaselineAnchor.constraint(
                equalTo: centerYAnchor, constant: Self.labelFont.capHeight / 2),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: controlStack.leadingAnchor, constant: -gap),
            controlStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyLabel()
        applyControlsShown(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // A press on the strip reaches the pane around it, which focuses the pane.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hoverDidChange() { applyControlsShown(animated: true) }

    func reapplyTheme() { applyLabel() }

    var labelForTesting: String { labelField.stringValue }
    var labelTruncationForTesting: NSLineBreakMode? { labelParagraphStyleForTesting?.lineBreakMode }
    var controlsForTesting: [Control] { controls }
    var visibleControlsForTesting: [Control] {
        controls.filter { buttons[$0]?.isHidden == false }
    }
    var controlsShownForTesting: Bool { controlsShown }
    func buttonForTesting(_ control: Control) -> IconButton? { buttons[control] }
    var labelInkForTesting: NSColor? {
        labelField.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
    var labelParagraphStyleForTesting: NSParagraphStyle? {
        guard labelField.attributedStringValue.length > 0 else { return nil }
        return labelField.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle
    }

    #if DEBUG
        func forceHoverForGallery() { setHovered(true) }
    #endif

    private func applyLabel() {
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = label.isPath ? .byTruncatingHead : .byTruncatingTail
        labelField.attributedStringValue = NSAttributedString(
            string: label.text,
            attributes: [
                .font: Self.labelFont,
                .foregroundColor: Theme.current.chrome.ink(.muted),
                .paragraphStyle: truncating,
            ])
        needsUpdateConstraints = true
    }

    private func applyControlsShown(animated: Bool) {
        let shown = isActive || showsHover
        guard shown != controlsShown || !animated else { return }
        controlsShown = shown
        if animated {
            Motion.fade(controlStack, to: shown ? 1 : 0)
        } else {
            controlStack.wantsLayer = true
            controlStack.layer?.opacity = shown ? 1 : 0
        }
    }

    @objc private func frameDidChange() { needsUpdateConstraints = true }

    // The label truncates first; every control but close drops out once the label would get less room than they take.
    override func updateConstraints() {
        let gap = ChromeMetrics.Spacing.s8
        let fullControls =
            ChromeMetrics.Height.xs * CGFloat(controls.count)
            + ChromeMetrics.Spacing.s2 * CGFloat(max(controls.count - 1, 0))
        let labelFloor = min(labelField.intrinsicContentSize.width, fullControls)
        let needed = labelFloor + gap + fullControls
        let collapsed = bounds.width > 0 && bounds.width < needed
        if collapsed != isCollapsed {
            isCollapsed = collapsed
            for (control, button) in buttons { button.isHidden = collapsed && control != .close }
        }
        super.updateConstraints()
    }
}
