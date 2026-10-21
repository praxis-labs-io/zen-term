import AppKit

final class WorkspaceTabChip: TabChip, NSTextFieldDelegate {
    var onSelect: (() -> Void)?
    var onRemove: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onRenamingChanged: (() -> Void)?
    var onWidthChanged: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var defaultName = ""
    private(set) var opensFocused = false
    private(set) var isRemovable = false
    private var hasFocus = false
    private var dragStartX: CGFloat?
    private var isDragging = false
    private var isCancellingRename = false

    private let renameField = NSTextField()

    var isSelected: Bool { isCurrent }
    var isRenaming: Bool { !renameField.isHidden }
    var renameFieldForTesting: NSTextField { renameField }

    override var showsClose: Bool { super.showsClose && !isRenaming }

    init() {
        super.init(closeLabel: "Remove tab", closeShortcut: { CommandCatalog.spec(for: .closeTab).shortcut })
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        onCloseButton = { [weak self] in self?.onRemove?() }

        renameField.isBordered = false
        renameField.drawsBackground = false
        renameField.focusRingType = .none
        renameField.font = Self.chipFont
        renameField.makeSingleLine()
        renameField.delegate = self
        renameField.isHidden = true
        renameField.translatesAutoresizingMaskIntoConstraints = true
        addSubview(renameField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(title: String, defaultName: String, selected: Bool, opensFocused: Bool, removable: Bool) {
        self.defaultName = defaultName
        self.opensFocused = opensFocused
        isRemovable = removable
        setAccessibilityLabel(title)
        setAccessibilitySelected(selected)
        apply(title: title, isCurrent: selected, isClosable: removable, dotColor: openFocusedDotColor)
    }

    private var openFocusedDotColor: NSColor? { opensFocused ? Theme.current.chrome.cursor.nsColor : nil }

    override var textWidth: CGFloat {
        guard isRenaming else { return super.textWidth }
        let typed = renameField.stringValue.isEmpty ? defaultName : renameField.stringValue
        let measured = (typed as NSString).size(withAttributes: [.font: Self.chipFont]).width
        return ceil(measured) + ChromeMetrics.Spacing.s12
    }

    override func layout() {
        super.layout()
        let fieldHeight = renameField.intrinsicContentSize.height
        renameField.frame = labelFrame.insetBy(dx: 0, dy: (bounds.height - fieldHeight) / 2)
    }

    override func reapplyTheme() {
        apply(title: title, isCurrent: isCurrent, isClosable: isClosable, dotColor: openFocusedDotColor)
        super.reapplyTheme()
        renameField.applyThemedEditor()
    }

    override func restyle() {
        super.restyle()
        let chrome = Theme.current.chrome
        renameField.textColor = chrome.ink(.normal)
        renameField.placeholderAttributedString = NSAttributedString(
            string: defaultName, attributes: [.font: Self.chipFont, .foregroundColor: chrome.ink(.muted)])
        let ringed = hasFocus || isRenaming
        layer?.borderWidth = ChromeMetrics.Border.width
        layer?.borderColor = ringed ? chrome.accent.nsColor.cgColor : NSColor.clear.cgColor
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { showFocus() }
        return ok
    }

    private func showFocus() {
        hasFocus = true
        restyle()
    }

    #if DEBUG
        func forceFocusForGallery() { showFocus() }
    #endif

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

    override func accessibilityPerformPress() -> Bool {
        guard !isRenaming else { return false }
        onSelect?()
        window?.makeFirstResponder(self)
        return true
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
        onWidthChanged?()
        needsLayout = true
        window?.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectAll(nil)
    }

    func commitRename() { endRename(commit: true, refocus: true) }

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
        onWidthChanged?()
        needsLayout = true
        onRenamingChanged?()
    }

    func controlTextDidChange(_ obj: Notification) {
        onWidthChanged?()
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
}
