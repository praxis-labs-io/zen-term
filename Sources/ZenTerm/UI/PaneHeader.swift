import AppKit

// The strip atop a terminal pane, drawer or float: its process chip, name and path, then its controls.
final class PaneHeader: ControlView, ThemeReapplying {
    struct Content: Equatable {
        var process: ProcessIcon
        var name: String
        var path: String?
    }

    enum Control: CaseIterable {
        // A float's `end` stops its program, where ⌘W only hides it: that is `minimize`'s shortcut.
        case splitHorizontal, splitVertical, focusMode, minimize, close, end

        var symbol: String {
            switch self {
            case .splitHorizontal: return "rectangle.split.1x2"
            case .splitVertical: return "rectangle.split.2x1"
            case .focusMode: return "arrow.up.left.and.arrow.down.right"
            case .minimize: return "minus"
            case .close, .end: return "xmark"
            }
        }

        var chord: KeyInterceptor.ReservedChord? {
            switch self {
            case .splitHorizontal: return .splitHorizontal
            case .splitVertical: return .splitVertical
            case .focusMode: return .toggleZoom
            case .close: return .closePane
            case .minimize, .end: return nil
            }
        }

        var label: String {
            switch self {
            case .minimize: return "Minimize"
            case .end: return "Close"
            default: return chord.map { CommandCatalog.spec(for: $0).title } ?? ""
            }
        }

        var shortcut: String? {
            switch self {
            case .minimize: return CommandCatalog.spec(for: .closePane).shortcut
            case .end: return nil
            default: return chord.map { CommandCatalog.spec(for: $0).shortcut }
            }
        }
    }

    var content: Content {
        didSet {
            guard content != oldValue else { return }
            if content.process != oldValue.process { chip.show(content.process) }
            applyText()
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

    // The header reads mostly in lowercase (`claude`, a path), so the name's x-height centers on the chip, not its line box.
    private static var nameFont: NSFont { ChromeType.font(.small, weight: .medium) }
    private static var pathFont: NSFont { ChromeType.font(.small) }

    private let controls: [Control]
    private let onControl: (Control) -> Void
    private let chip: IconBadge
    private let nameField = NSTextField(labelWithString: "")
    private let pathField = NSTextField(labelWithString: "")
    private let controlStack = NSStackView()
    private var buttons: [Control: IconButton] = [:]
    private var isCollapsed = false
    private var controlsShown = false

    init(content: Content, controls: [Control], onControl: @escaping (Control) -> Void) {
        self.content = content
        self.controls = controls
        self.onControl = onControl
        chip = IconBadge(process: content.process, size: .small)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange), name: NSView.frameDidChangeNotification, object: self)

        for field in [nameField, pathField] {
            field.makeSingleLine()
            field.maximumNumberOfLines = 1
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        nameField.lineBreakMode = .byTruncatingTail
        pathField.lineBreakMode = .byTruncatingHead
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        controlStack.orientation = .horizontal
        controlStack.spacing = ChromeMetrics.Spacing.s2
        controlStack.translatesAutoresizingMaskIntoConstraints = false
        controlStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        for control in controls {
            let button = IconButton(
                symbol: control.symbol,
                size: NSSize(width: ChromeMetrics.Height.xs, height: ChromeMetrics.Height.xs),
                pointSize: ChromeMetrics.Icon.xs, accessibilityLabel: control.label,
                shortcut: control.shortcut.map { _ in { control.shortcut } }, restInk: .muted,
                onClick: { [weak self] in self?.onControl(control) })
            button.firesOnRelease = true
            buttons[control] = button
            controlStack.addArrangedSubview(button)
        }

        chip.translatesAutoresizingMaskIntoConstraints = false
        [chip, nameField, pathField, controlStack].forEach(addSubview)
        let gap = ChromeMetrics.Spacing.s8
        NSLayoutConstraint.activate([
            Self.yieldingGap(after: nameField, before: pathField),
            heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.xs),
            chip.leadingAnchor.constraint(equalTo: leadingAnchor),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: gap),
            nameField.firstBaselineAnchor.constraint(
                equalTo: chip.centerYAnchor, constant: Self.nameFont.xHeight / 2),
            pathField.firstBaselineAnchor.constraint(equalTo: nameField.firstBaselineAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: controlStack.leadingAnchor, constant: -gap),
            pathField.trailingAnchor.constraint(lessThanOrEqualTo: controlStack.leadingAnchor, constant: -gap),
            controlStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyText()
        applyControlsShown(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // An empty path still holds its gap, so in a header too narrow for both gaps it is the one that gives.
    private static func yieldingGap(after name: NSView, before path: NSView) -> NSLayoutConstraint {
        let gap = path.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: ChromeMetrics.Spacing.s8)
        gap.priority = .defaultHigh
        return gap
    }

    // A press on the strip reaches the pane around it, which focuses the pane.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hoverDidChange() { applyControlsShown(animated: true) }

    func reapplyTheme() { applyText() }

    var nameForTesting: String { nameField.stringValue }
    var pathForTesting: String? { pathField.isHidden ? nil : pathField.stringValue }
    var processForTesting: ProcessIcon { content.process }
    var controlsForTesting: [Control] { controls }
    var visibleControlsForTesting: [Control] {
        controls.filter { buttons[$0]?.isHidden == false }
    }
    var controlsShownForTesting: Bool { controlsShown }
    func buttonForTesting(_ control: Control) -> IconButton? { buttons[control] }
    var inksForTesting: (name: NSColor?, path: NSColor?) { (ink(of: nameField), ink(of: pathField)) }
    var pathTruncationForTesting: NSLineBreakMode? { paragraphStyle(of: pathField)?.lineBreakMode }

    #if DEBUG
        func forceHoverForGallery() { setHovered(true) }
    #endif

    private func ink(of field: NSTextField) -> NSColor? {
        guard field.attributedStringValue.length > 0 else { return nil }
        return field.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    private func paragraphStyle(of field: NSTextField) -> NSParagraphStyle? {
        guard field.attributedStringValue.length > 0 else { return nil }
        return field.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    }

    private func applyText() {
        let ink = Theme.current.chrome.ink(.muted)
        nameField.attributedStringValue = Self.text(
            content.name, font: Self.nameFont, ink: ink, truncation: .byTruncatingTail)
        pathField.isHidden = content.path == nil
        pathField.attributedStringValue = Self.text(
            content.path ?? "", font: Self.pathFont, ink: ink, truncation: .byTruncatingHead)
        needsUpdateConstraints = true
    }

    private static func text(_ string: String, font: NSFont, ink: NSColor, truncation: NSLineBreakMode)
        -> NSAttributedString
    {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncation
        return NSAttributedString(
            string: string, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: style])
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

    // The path truncates first, then the name; every control but close drops out once the name would get less room than they take.
    override func updateConstraints() {
        let gap = ChromeMetrics.Spacing.s8
        let fullControls =
            ChromeMetrics.Height.xs * CGFloat(controls.count)
            + ChromeMetrics.Spacing.s2 * CGFloat(max(controls.count - 1, 0))
        let nameFloor = min(nameField.intrinsicContentSize.width, fullControls)
        let needed = IconBadge.Size.small.side + gap + nameFloor + gap + fullControls
        let collapsed = bounds.width > 0 && bounds.width < needed
        if collapsed != isCollapsed {
            isCollapsed = collapsed
            for (control, button) in buttons { button.isHidden = collapsed && control != .close && control != .end }
        }
        super.updateConstraints()
    }
}
