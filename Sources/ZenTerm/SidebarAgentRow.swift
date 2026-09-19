import AppKit

struct SidebarAgentItem: Equatable {
    enum State: Equatable {
        case waiting, working, done, failed, idle

        init(_ attention: SurfaceAttention, failed: Bool) {
            switch attention {
            case .waiting: self = .waiting
            case .working: self = .working
            case .completed: self = failed ? .failed : .done
            case .idle: self = .idle
            }
        }

        var rank: Int {
            switch self {
            case .waiting: return 0
            case .working: return 1
            case .done, .failed: return 2
            case .idle: return 3
            }
        }

        var summary: String {
            switch self {
            case .waiting: return "Waiting"
            case .working: return "Working"
            case .done: return "Done"
            case .failed: return "Exited"
            case .idle: return "Idle"
            }
        }
    }

    let id: SurfaceID
    let state: State
    let summary: String
    let detail: String
}

final class SidebarAgentRow: NSView, HoverSuppressing {
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onEscape: (() -> Void)?

    private let summaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let glyphSlot = NSView()
    private let dot = NSView()
    private let spinner = Spinner()
    private let check = NSImageView()
    private let onActivate: () -> Void
    private var item: SidebarAgentItem?
    private let tooltip = TooltipHost(label: "Jump to agent")
    private var isTakingKeyboardFocus = false
    private var trackingArea: NSTrackingArea?
    private var isFocusedStop = false
    private var isHovered = false
    private var isHoverSuppressed = false

    static let height: CGFloat = 47
    private static let inset: CGFloat = 10
    private static let top: CGFloat = 7
    private static let glyphSize = NSSize(width: 14, height: 16)
    private static let glyphGap: CGFloat = 8
    private static let lineGap: CGFloat = 3
    private static let dotDiameter: CGFloat = 7

    init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        summaryLabel.font = .systemFont(ofSize: 12)
        detailLabel.font = .systemFont(ofSize: 11)
        for label in [summaryLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotDiameter / 2
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        glyphSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphSlot)
        for glyph in [dot, spinner, check] {
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyphSlot.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.trailingAnchor.constraint(equalTo: glyphSlot.trailingAnchor),
                glyph.centerYAnchor.constraint(equalTo: glyphSlot.centerYAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            glyphSlot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            glyphSlot.topAnchor.constraint(equalTo: topAnchor, constant: Self.top),
            glyphSlot.widthAnchor.constraint(equalToConstant: Self.glyphSize.width),
            glyphSlot.heightAnchor.constraint(equalToConstant: Self.glyphSize.height),
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            summaryLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: glyphSlot.leadingAnchor, constant: -Self.glyphGap),
            summaryLabel.centerYAnchor.constraint(equalTo: glyphSlot.centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: glyphSlot.leadingAnchor, constant: -Self.glyphGap),
            detailLabel.topAnchor.constraint(equalTo: glyphSlot.bottomAnchor, constant: Self.lineGap),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ item: SidebarAgentItem) {
        guard item != self.item else { return }
        self.item = item
        summaryLabel.stringValue = item.summary
        detailLabel.stringValue = item.detail
        setAccessibilityLabel(item.summary)
        setAccessibilityValue(item.detail)
        dot.isHidden = item.state != .waiting && item.state != .failed
        spinner.isHidden = item.state != .working
        spinner.isSpinning = item.state == .working
        check.isHidden = item.state != .done
        reapplyTheme()
    }

    var itemForTesting: SidebarAgentItem? { item }

    var fillForTesting: CGColor? { layer?.backgroundColor }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        let isQuiet = item?.state == .done || item?.state == .idle
        summaryLabel.textColor = chrome.ink(isQuiet ? .subtle : .normal)
        detailLabel.textColor = chrome.ink(.muted)
        dot.layer?.backgroundColor =
            (item?.state == .failed ? chrome.destructive : chrome.attention).nsColor.cgColor
        check.contentTintColor = chrome.positive.nsColor
        spinner.reapplyTheme()
        refreshFill()
    }

    private func refreshFill() {
        let chrome = Theme.current.chrome
        if isFocusedStop {
            layer?.backgroundColor = chrome.selectionFill.cgColor
        } else if isHovered, !isHoverSuppressed {
            layer?.backgroundColor = chrome.fill(.hover).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    // AppKit promotes any clicked view that accepts, so a row accepts only in `takeKeyboardFocus`.
    override var acceptsFirstResponder: Bool { isTakingKeyboardFocus }

    func takeKeyboardFocus() {
        isTakingKeyboardFocus = true
        window?.makeFirstResponder(self)
        isTakingKeyboardFocus = false
    }
    override func becomeFirstResponder() -> Bool { isFocusedStop = true; refreshFill(); return true }
    override func resignFirstResponder() -> Bool { isFocusedStop = false; refreshFill(); return true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshFill()
        guard !isHoverSuppressed else { return }
        tooltip.show(from: self)
    }

    func setHoverSuppressed(_ suppressed: Bool) {
        guard suppressed != isHoverSuppressed else { return }
        isHoverSuppressed = suppressed
        if suppressed { tooltip.hide(from: self) } else { isHovered = pointerIsInside }
        refreshFill()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshFill()
        tooltip.hide(from: self)
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
        refreshFill()
        tooltip.hide(from: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip.hide(from: self) }
    }

    override func accessibilityPerformPress() -> Bool { onActivate(); return true }

    override func mouseDown(with event: NSEvent) {
        tooltip.hide(from: self)
        onActivate()
    }

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .activate where KeyboardFocus.isReturn(event): onActivate()
        case .escape where onEscape != nil && KeyboardFocus.isUnmodified(event): onEscape?()
        default: super.keyDown(with: event)
        }
    }
}
