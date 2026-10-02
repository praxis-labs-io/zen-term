import AppKit

final class WorkspaceTabChip: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 26
    private static let inset: CGFloat = 10
    private static let dotDiameter: CGFloat = 6
    private static let accessorySpacing: CGFloat = 6
    private static let closeSize: CGFloat = 16

    var onSelect: (() -> Void)?
    var onRemove: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onRenamingChanged: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private(set) var title = ""
    private var defaultName = ""
    private(set) var isSelected = false
    private(set) var opensFocused = false
    private(set) var isRemovable = false
    private var isHovered = false
    private var hasFocus = false
    private var dragStartX: CGFloat?
    private var isDragging = false
    private var isCancellingRename = false

    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let underline = NSView()
    private lazy var closeButton = IconButton(
        symbol: "xmark", size: NSSize(width: Self.closeSize, height: Self.closeSize), pointSize: 8,
        weight: .semibold, accessibilityLabel: "Remove tab", shortcut: { CommandCatalog.spec(for: .closeTab).shortcut }
    ) { [weak self] in self?.onRemove?() }
    private let renameField = RenameField()

    var isRenaming: Bool { !renameField.isHidden }
    var renameFieldForTesting: NSTextField { renameField }
    var isCloseVisibleForTesting: Bool { !closeButton.isHidden }
    var isDotVisibleForTesting: Bool { !dot.isHidden }
    var closeButtonForTesting: IconButton { closeButton }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotDiameter / 2
        dot.setAccessibilityLabel("Opens focused")

        underline.wantsLayer = true
        underline.layer?.cornerRadius = 1

        renameField.isBordered = false
        renameField.drawsBackground = false
        renameField.focusRingType = .none
        renameField.font = TabBarView.chipFont
        renameField.cell?.isScrollable = true
        renameField.delegate = self
        renameField.isHidden = true

        for view in [label, dot, underline, closeButton, renameField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(title: String, defaultName: String, selected: Bool, opensFocused: Bool, removable: Bool) {
        self.title = title
        self.defaultName = defaultName
        isSelected = selected
        self.opensFocused = opensFocused
        isRemovable = removable
        setAccessibilityLabel(title)
        restyle()
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        let text = isRenaming ? renameWidth : ceil(label.attributedStringValue.size().width) + 2
        var width = Self.inset * 2 + text
        if opensFocused { width += Self.accessorySpacing + Self.dotDiameter }
        if showsClose { width += Self.accessorySpacing / 2 + Self.closeSize }
        return min(width, TabBarView.maxChipWidth)
    }

    private var renameWidth: CGFloat {
        let typed = renameField.stringValue.isEmpty ? defaultName : renameField.stringValue
        let measured = (typed as NSString).size(withAttributes: [.font: TabBarView.chipFont]).width
        return max(ceil(measured) + 12, 72)
    }

    private var showsClose: Bool { isRemovable && !isRenaming && (isSelected || isHovered) }

    override func layout() {
        super.layout()
        var trailing = bounds.width - Self.inset
        closeButton.isHidden = !showsClose
        if showsClose {
            trailing += Self.inset - Self.accessorySpacing
            closeButton.frame = CGRect(
                x: trailing - Self.closeSize, y: (bounds.height - Self.closeSize) / 2,
                width: Self.closeSize, height: Self.closeSize)
            trailing -= Self.closeSize + Self.accessorySpacing / 2
        }
        dot.isHidden = !opensFocused
        if opensFocused {
            dot.frame = CGRect(
                x: trailing - Self.dotDiameter, y: (bounds.height - Self.dotDiameter) / 2,
                width: Self.dotDiameter, height: Self.dotDiameter)
            trailing -= Self.dotDiameter + Self.accessorySpacing
        }
        let textFrame = CGRect(x: Self.inset, y: 0, width: max(0, trailing - Self.inset), height: bounds.height)
        let labelHeight = label.intrinsicContentSize.height
        label.frame = textFrame.insetBy(dx: 0, dy: (bounds.height - labelHeight) / 2)
        let fieldHeight = renameField.intrinsicContentSize.height
        renameField.frame = textFrame.insetBy(dx: 0, dy: (bounds.height - fieldHeight) / 2)
        underline.frame = CGRect(x: Self.inset, y: 0, width: max(0, bounds.width - 2 * Self.inset), height: 2)
    }

    func reapplyTheme() {
        closeButton.reapplyTheme()
        restyle()
    }

    private func restyle() {
        let chrome = Theme.current.chrome
        let ink = chrome.ink(isSelected || isHovered ? .normal : .subtle)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        label.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: TabBarView.chipFont, .kern: TabBarView.titleKern, .foregroundColor: ink,
                .paragraphStyle: paragraph,
            ])
        renameField.textColor = chrome.ink(.normal)
        renameField.placeholderAttributedString = NSAttributedString(
            string: defaultName, attributes: [.font: TabBarView.chipFont, .foregroundColor: chrome.ink(.faint)])
        dot.layer?.backgroundColor = chrome.cursor.nsColor.cgColor
        underline.layer?.backgroundColor = chrome.accent.nsColor.cgColor
        underline.isHidden = !isSelected || isRenaming
        let background: NSColor
        if isSelected {
            background = chrome.selectionFill
        } else if isHovered {
            background = chrome.fill(.hover)
        } else {
            background = .clear
        }
        layer?.backgroundColor = background.cgColor
        let ringed = hasFocus || isRenaming
        layer?.borderWidth = ringed ? 1.5 : 0
        layer?.borderColor = ringed ? chrome.accent.nsColor.cgColor : nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            hasFocus = true
            restyle()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        hasFocus = false
        restyle()
        return super.resignFirstResponder()
    }

    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .left: onArrowLeft?()
        case .right: onArrowRight?()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .tab(let shift): (shift ? onBacktab : onTab)?()
        case .activate where KeyboardFocus.isUnmodified(event): beginRename()
        default: super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ on: Bool) {
        guard isHovered != on else { return }
        isHovered = on
        restyle()
        superview?.needsLayout = true
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        guard !isRenaming else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            beginRename()
            return
        }
        onSelect?()
        window?.makeFirstResponder(self)
        dragStartX = superview?.convert(event.locationInWindow, from: nil).x
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX, let x = superview?.convert(event.locationInWindow, from: nil).x else { return }
        let offset = x - dragStartX
        if !isDragging {
            guard abs(offset) > 3 else { return }
            isDragging = true
            onDragBegan?()
        }
        onDragged?(offset)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        guard isDragging else { return }
        isDragging = false
        onDragEnded?()
    }

    func beginRename() {
        guard !isRenaming else { return }
        onSelect?()
        renameField.stringValue = title == defaultName ? "" : title
        renameField.isHidden = false
        label.isHidden = true
        onRenamingChanged?()
        restyle()
        superview?.needsLayout = true
        needsLayout = true
        window?.makeFirstResponder(renameField)
        renameField.applyThemedCaret()
        renameField.currentEditor()?.selectAll(nil)
    }

    @discardableResult
    func cancelRename() -> Bool {
        guard isRenaming else { return false }
        isCancellingRename = true
        endRename(commit: false, refocus: true)
        isCancellingRename = false
        return true
    }

    private func endRename(commit: Bool, refocus: Bool) {
        guard isRenaming else { return }
        let typed = renameField.stringValue
        renameField.isHidden = true
        label.isHidden = false
        if refocus { window?.makeFirstResponder(self) }
        if commit { onRename?(typed) }
        restyle()
        superview?.needsLayout = true
        needsLayout = true
        onRenamingChanged?()
    }

    func controlTextDidChange(_ obj: Notification) {
        superview?.needsLayout = true
        needsLayout = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isCancellingRename else { return }
        endRename(commit: true, refocus: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endRename(commit: true, refocus: true)
        case #selector(NSResponder.cancelOperation(_:)):
            cancelRename()
        default:
            return false
        }
        return true
    }

    private final class RenameField: NSTextField {
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { applyThemedCaret() }
            return ok
        }
    }
}
