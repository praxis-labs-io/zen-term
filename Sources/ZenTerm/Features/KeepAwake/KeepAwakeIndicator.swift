import AppKit

// The sidebar footer's Keep Awake control: a cup at rest, the cup and what ends the hold while it is on.
final class KeepAwakeIndicator: ControlView, ThemeReapplying {
    struct Content: Equatable {
        var isOn = false
        var keepsDisplayOn = false
        var detail: String?
        var isBatteryLow = false
    }

    static let cupSymbol = "cup.and.saucer"
    private static let displaySymbol = "display"
    private static let side = ChromeMetrics.Height.sm
    private static let leadingInset = ChromeMetrics.Spacing.s6
    private static let trailingInset = ChromeMetrics.Spacing.s8
    private static let gap = ChromeMetrics.Spacing.s6

    var onClick: () -> Void
    var isActive = false { didSet { restyle() } }
    private(set) var content = Content()

    private let cup = GlyphView()
    private let display = GlyphView()
    private let awakeLabel = NSTextField(labelWithString: "Awake")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let tooltip = TooltipHost(label: "Keep Awake")
    private lazy var offConstraints = [
        widthAnchor.constraint(equalToConstant: Self.side),
        stack.centerXAnchor.constraint(equalTo: centerXAnchor),
    ]
    private lazy var onConstraints = [
        stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
        stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
    ]

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        translatesAutoresizingMaskIntoConstraints = false

        for (glyph, symbol) in [(cup, Self.cupSymbol), (display, Self.displaySymbol)] {
            glyph.image = IconCatalog.image(symbol, pointSize: ChromeMetrics.Icon.sm)
            glyph.imageScaling = .scaleNone
            glyph.setContentHuggingPriority(.required, for: .horizontal)
        }
        awakeLabel.font = ChromeType.font(.caption, weight: .medium)
        detailLabel.font = ChromeType.font(.caption, face: .digits)
        for label in [awakeLabel, detailLabel] {
            label.lineBreakMode = .byClipping
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [cup, display, awakeLabel, detailLabel] { stack.addArrangedSubview(view) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.side),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Keep Awake")
        render(content, force: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ content: Content) { render(content, force: false) }

    func reapplyTheme() { restyle() }

    override func hoverDidChange() {
        if !showsHover { tooltip.hide(from: self) }
        restyle()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHoverSuppressed else { return }
        tooltip.show(from: self)
    }

    override func mouseDown(with event: NSEvent) {
        tooltip.hide(from: self)
        onClick()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    override func accessibilityValue() -> Any? {
        guard content.isOn else { return "Off" }
        let parts = [content.keepsDisplayOn ? "display on" : nil, content.detail, content.isBatteryLow ? "battery low" : nil]
        return (["Awake"] + parts.compactMap { $0 })
            .joined(separator: ", ")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip.hide(from: self) }
    }

    var cupTintForTesting: NSColor? { cup.contentTintColor }
    var showsDisplayForTesting: Bool { !display.isHidden }
    var awakeTextForTesting: String? { awakeLabel.isHidden ? nil : awakeLabel.stringValue }
    var detailTextForTesting: String? { detailLabel.isHidden ? nil : detailLabel.stringValue }

    #if DEBUG
        func forceHoverForGallery() { setHovered(true) }
    #endif

    private func render(_ content: Content, force: Bool) {
        guard force || content != self.content else { return }
        self.content = content
        display.isHidden = !(content.isOn && content.keepsDisplayOn)
        awakeLabel.isHidden = !content.isOn
        detailLabel.stringValue = content.detail ?? ""
        detailLabel.isHidden = !content.isOn || content.detail == nil
        NSLayoutConstraint.deactivate(content.isOn ? offConstraints : onConstraints)
        NSLayoutConstraint.activate(content.isOn ? onConstraints : offConstraints)
        restyle()
    }

    private func restyle() {
        let chrome = Theme.current.chrome
        let fill: NSColor
        if isActive {
            fill = chrome.fill(.active)
        } else if showsHover {
            fill = chrome.fill(.hover)
        } else {
            fill = .clear
        }
        easeFill(fill)
        let ink = chrome.ink(showsHover || isActive ? .normal : .subtle)
        let held = content.isBatteryLow ? chrome.warning.nsColor : chrome.accent.nsColor
        cup.contentTintColor = content.isOn ? held : ink
        display.contentTintColor = chrome.accent.nsColor
        awakeLabel.textColor = ink
        detailLabel.textColor = chrome.ink(.muted)
    }
}
