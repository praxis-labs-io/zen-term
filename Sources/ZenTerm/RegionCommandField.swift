import AppKit

// One region of a tab drawing: its label, its command, and whether the workspace opens focused there.
final class RegionCommandField: NSView, NSTextFieldDelegate {
    enum Edge { case left, right, up, down }

    static let commandFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let horizontalInset: CGFloat = 11
    private static let topInset: CGFloat = 9
    private static let rowSpacing: CGFloat = 9
    private static let markerSize = NSSize(width: 8, height: 16)
    private static let markerSpacing: CGFloat = 7
    private static let cornerSize: CGFloat = 24
    private static let cornerInset: CGFloat = 6

    let region: Workspace.Region
    let field = CommandField()
    var onChange: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onEdge: ((Edge) -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onOpenFocusedHere: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let opensFocusedLabel = NSTextField(labelWithString: "Opens focused")
    private let marker = NSView()
    private lazy var cornerButton = IconButton(
        symbol: "viewfinder", size: NSSize(width: Self.cornerSize, height: Self.cornerSize), pointSize: 12,
        accessibilityLabel: "Open with focus here", shortcut: { WorkspaceTabDrawing.launchFocusShortcut }
    ) { [weak self] in self?.onOpenFocusedHere?() }
    private(set) var opensFocused = false
    private var isHovered = false
    private(set) var isEditing = false

    var isCornerButtonVisibleForTesting: Bool { !cornerButton.isHidden }
    var cornerButtonForTesting: IconButton { cornerButton }
    var isMarkerVisibleForTesting: Bool { !marker.isHidden && !opensFocusedLabel.isHidden }

    init(region: Workspace.Region) {
        self.region = region
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        label.stringValue = WorkspaceForm.label(for: region)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        opensFocusedLabel.font = .systemFont(ofSize: 10.5, weight: .medium)

        marker.wantsLayer = true
        marker.layer?.cornerRadius = 1

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.commandFont
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byClipping
        field.delegate = self
        field.onGainedFocus = { [weak self] in self?.setEditing(true) }

        for view in [label, opensFocusedLabel, marker, field, cornerButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var text: String { field.stringValue }

    func setText(_ value: String) {
        guard field.stringValue.trimmingCharacters(in: .whitespaces) != value else { return }
        field.stringValue = value
    }

    func setOpensFocused(_ on: Bool) {
        opensFocused = on
        refresh()
    }

    var fittingTextWidth: CGFloat {
        let typed = (field.stringValue as NSString).size(withAttributes: [.font: Self.commandFont]).width
        return ceil(typed) + 2 * Self.horizontalInset + Self.markerSize.width + Self.markerSpacing + 8
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        label.textColor = chrome.ink(.muted)
        opensFocusedLabel.textColor = chrome.cursor.nsColor
        marker.layer?.backgroundColor = chrome.cursor.nsColor.cgColor
        field.textColor = chrome.foreground.nsColor
        field.applyThemedCaret()
        let placeholder = region == .main ? WorkspaceForm.shellLabel : ""
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.font: Self.commandFont, .foregroundColor: chrome.ink(.faint)])
        cornerButton.reapplyTheme()
        refresh()
    }

    private func refresh() {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = (isEditing ? chrome.selectionFill : chrome.fill(.rest)).cgColor
        layer?.borderColor = (isEditing ? chrome.accent.nsColor : chrome.fill(alpha: ChromeTheme.border)).cgColor
        layer?.borderWidth = isEditing ? 1.5 : 1
        marker.isHidden = !opensFocused
        opensFocusedLabel.isHidden = !opensFocused
        cornerButton.isHidden = !(isHovered || isEditing)
        cornerButton.isActive = opensFocused
        needsLayout = true
    }

    private func setEditing(_ on: Bool) {
        guard isEditing != on else { return }
        isEditing = on
        refresh()
        if on { onFocused?() }
    }

    override func layout() {
        super.layout()
        let labelSize = label.intrinsicContentSize
        label.frame = CGRect(origin: CGPoint(x: Self.horizontalInset, y: Self.topInset), size: labelSize)
        let flagSize = opensFocusedLabel.intrinsicContentSize
        opensFocusedLabel.frame = CGRect(
            x: label.frame.maxX + 8, y: label.frame.midY - flagSize.height / 2, width: flagSize.width,
            height: flagSize.height)
        cornerButton.frame = CGRect(
            x: bounds.width - Self.cornerInset - Self.cornerSize, y: Self.cornerInset, width: Self.cornerSize,
            height: Self.cornerSize)
        let rowY = label.frame.maxY + Self.rowSpacing
        var x = Self.horizontalInset
        if opensFocused {
            marker.frame = CGRect(origin: CGPoint(x: x, y: rowY + 1), size: Self.markerSize)
            x += Self.markerSize.width + Self.markerSpacing
        }
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = CGRect(
            x: x - 2, y: rowY + (Self.markerSize.height + 2 - fieldHeight) / 2,
            width: max(0, bounds.width - x - Self.horizontalInset + 2), height: fieldHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func controlTextDidEndEditing(_ obj: Notification) {
        setEditing(false)
        onEndEditing?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            onEdge?(.up)
        case #selector(NSResponder.moveDown(_:)):
            onEdge?(.down)
        case #selector(NSResponder.moveLeft(_:)):
            guard textView.selectedRange() == NSRange(location: 0, length: 0) else { return false }
            onEdge?(.left)
        case #selector(NSResponder.moveRight(_:)):
            let end = (textView.string as NSString).length
            guard textView.selectedRange() == NSRange(location: end, length: 0) else { return false }
            onEdge?(.right)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            guard NSApp.currentEvent?.modifierFlags.contains(.command) != true else { return false }
            onEdge?(.down)
        case #selector(NSResponder.insertTab(_:)):
            guard let onTab else { return false }
            onTab()
        case #selector(NSResponder.insertBacktab(_:)):
            guard let onBacktab else { return false }
            onBacktab()
        default:
            return false
        }
        return true
    }

    final class CommandField: NSTextField {
        var onGainedFocus: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok {
                applyThemedCaret()
                onGainedFocus?()
            }
            return ok
        }
    }
}
