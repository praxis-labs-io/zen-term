import AppKit
import TerminalKit

// The scrollback search field a pane wears over its header's top-right corner while a search runs.
final class FindField: NSView, ThemeReapplying {
    private let glyph = NSImageView()
    private let field = FocusReportingField()
    private let count = NSTextField(labelWithString: "")
    private let divider = ToolbarDivider()
    private let queryFade = EdgeFade(axis: .horizontal)
    private weak var observedEditorClip: NSClipView?
    private var olderButton: IconButton!
    private var newerButton: IconButton!
    private var closeButton: IconButton!
    private let buttons = NSStackView()

    var onChange: ((String) -> Void)?
    var onStep: ((TerminalSearchStep) -> Void)?
    var onCancel: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var isDismissed = false

    // Flat, the field is the header's row: no card, no glyph, since the header's chip carries it.
    var isFlat = false {
        didSet {
            guard isFlat != oldValue else { return }
            applyLook()
        }
    }
    private var heightConstraint: NSLayoutConstraint?
    private var cardWidth: [NSLayoutConstraint] = []
    private var row: NSStackView?

    /// Setting it doesn't fire `onChange`, so a seed from a selection doesn't re-run its search.
    var needle: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            refreshQueryFade()
        }
    }

    static let height: CGFloat = ChromeMetrics.Height.control
    // The board's width: no token holds a field this wide, and the pane can always shrink it.
    static let width: CGFloat = 300
    private static let buttonSize = NSSize(width: ChromeMetrics.Height.xs, height: ChromeMetrics.Height.xs)
    private static let queryFadeDepth: CGFloat = ChromeMetrics.Spacing.s16

    // The copy is English throughout, so the grouping follows it rather than the system region.
    private static let countFormat = IntegerFormatStyle<Int>.number.locale(Locale(identifier: "en_US"))

    init() {
        super.init(frame: .zero)

        glyph.image = IconCatalog.image("magnifyingglass", pointSize: ChromeMetrics.Icon.sm, weight: .regular)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)

        field.font = ChromeType.font(.small)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.makeSingleLine()
        field.lineBreakMode = .byClipping
        field.wantsLayer = true
        field.delegate = self
        field.onFocus = { [weak self] in
            self?.observeEditorScroll()
            self?.onFocusChange?(true)
        }
        field.onEditorDetached = { [weak self] in
            self?.stopObservingEditorScroll()
            self?.refreshQueryFade()
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        count.font = ChromeType.font(.small, face: .digits)
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        buttons.orientation = .horizontal
        buttons.spacing = ChromeMetrics.Spacing.s2
        buttons.setHuggingPriority(.required, for: .horizontal)
        buildButtons()

        let row = NSStackView(views: [glyph, field, count, buttons])
        row.orientation = .horizontal
        row.spacing = ChromeMetrics.Spacing.s8
        row.edgeInsets = NSEdgeInsets(
            top: 0, left: ChromeMetrics.Spacing.controlInset, bottom: 0, right: ChromeMetrics.Spacing.s4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let preferredWidth = widthAnchor.constraint(equalToConstant: Self.width)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        cardWidth = [widthAnchor.constraint(lessThanOrEqualToConstant: Self.width), preferredWidth]
        NSLayoutConstraint.activate(cardWidth)
        self.row = row
        let height = heightAnchor.constraint(equalToConstant: Self.height)
        height.isActive = true
        heightConstraint = height

        CardChrome.apply(to: self, cornerRadius: ChromeMetrics.Radius.control, tier: .overlay)
        showCount(total: nil, selected: nil)
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Flat in the header, the buttons take the header's own control size and ink, and close reads as find's, not the pane's.
    private func buildButtons() {
        let pointSize = isFlat ? ChromeMetrics.Icon.xs : ChromeMetrics.Icon.sm
        let restInk: ChromeTheme.InkLevel = isFlat ? .muted : .subtle
        func button(_ symbol: String, _ label: String, _ shortcut: String, _ action: @escaping () -> Void)
            -> IconButton
        {
            IconButton(
                symbol: symbol, size: Self.buttonSize, pointSize: pointSize, accessibilityLabel: label,
                shortcut: { shortcut }, restInk: restInk, onClick: action)
        }
        let enabled = olderButton?.isEnabled ?? false
        olderButton = button("chevron.up", "Older Match", "↩") { [weak self] in self?.onStep?(.next) }
        newerButton = button("chevron.down", "Newer Match", "⇧↩") { [weak self] in self?.onStep?(.previous) }
        closeButton = button(isFlat ? "escape" : "xmark", "Close Find", "esc") { [weak self] in
            self?.onCancel?()
        }
        olderButton.isEnabled = enabled
        newerButton.isEnabled = enabled
        for view in buttons.arrangedSubviews { view.removeFromSuperview() }
        let views: [NSView] = (isFlat ? [] : [divider]) + [olderButton, newerButton, closeButton]
        for view in views { buttons.addArrangedSubview(view) }
        if !isFlat { buttons.setCustomSpacing(ChromeMetrics.Spacing.s4, after: divider) }
    }

    /// `selected` is zero-based and newest-first, libghostty's order; the count shows oldest-first.
    func showCount(total: Int?, selected: Int?) {
        let format = Self.countFormat
        switch (total, selected) {
        case (nil, _):
            count.stringValue = ""
        case (0, _):
            count.stringValue = "No matches"
        case (1, nil):
            count.stringValue = "1 match"
        case (let total?, nil):
            count.stringValue = "\(total.formatted(format)) matches"
        case (let total?, let selected?):
            count.stringValue = "\(max(1, total - selected).formatted(format)) / \(total.formatted(format))"
        }
        let canStep = (total ?? 0) > 0
        olderButton.isEnabled = canStep
        newerButton.isEnabled = canStep
    }

    func focusField() {
        window?.makeFirstResponder(field)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isDismissed ? nil : super.hitTest(point) }

    override func layout() {
        super.layout()
        refreshQueryFade()
    }

    // The field editor is shared by the window, so its clip view is watched only while it edits this field.
    private func observeEditorScroll() {
        guard let clip = (field.currentEditor() as? NSTextView)?.superview as? NSClipView,
            clip !== observedEditorClip
        else { return }
        stopObservingEditorScroll()
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshQueryFade), name: NSView.boundsDidChangeNotification, object: clip)
        observedEditorClip = clip
    }

    private func stopObservingEditorScroll() {
        guard let clip = observedEditorClip else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
        observedEditorClip = nil
    }

    @objc private func refreshQueryFade() {
        if field.layer?.mask !== queryFade.layer { field.layer?.mask = queryFade.layer }
        let hidden = queryOverflow
        queryFade.update(
            frame: field.bounds, start: hidden.start ? Self.queryFadeDepth : 0,
            end: hidden.end ? Self.queryFadeDepth : 0)
    }

    private var queryOverflow: (start: Bool, end: Bool) {
        let visibleWidth = field.cell?.drawingRect(forBounds: field.bounds).width ?? field.bounds.width
        guard let editor = field.currentEditor() as? NSTextView, let container = editor.textContainer,
            let layout = editor.layoutManager
        else {
            return (false, field.attributedStringValue.size().width - visibleWidth > 0.5)
        }
        layout.ensureLayout(for: container)
        let textWidth = layout.usedRect(for: container).width
        let shown = editor.visibleRect
        return (shown.minX > 0.5, textWidth - shown.maxX > 0.5)
    }

    var isFieldFirstResponder: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    var countTextForTesting: String { count.stringValue }
    var olderButtonForTesting: IconButton { olderButton }
    var newerButtonForTesting: IconButton { newerButton }
    var closeButtonForTesting: IconButton { closeButton }

    var fadedQueryEdgesForTesting: (start: Bool, end: Bool) {
        let colors = (queryFade.layer.colors as? [CGColor]) ?? []
        return (colors.first?.alpha == 0, colors.last?.alpha == 0)
    }

    private func applyLook() {
        glyph.isHidden = isFlat
        buildButtons()
        reapplyTheme()
        heightConstraint?.constant = isFlat ? ChromeMetrics.Height.xs : Self.height
        for constraint in cardWidth { constraint.isActive = !isFlat }
        row?.edgeInsets = NSEdgeInsets(
            top: 0, left: isFlat ? 0 : ChromeMetrics.Spacing.controlInset, bottom: 0,
            right: isFlat ? 0 : ChromeMetrics.Spacing.s4)
        if isFlat {
            layer?.backgroundColor = nil
            layer?.borderWidth = 0
            layer?.shadowOpacity = 0
        } else {
            CardChrome.apply(to: self, cornerRadius: ChromeMetrics.Radius.control, tier: .overlay)
        }
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        if !isFlat { CardChrome.reapplyTheme(to: self, tier: .overlay) }
        field.applyThemedEditor()
        glyph.contentTintColor = chrome.ink(.muted)
        field.textColor = chrome.ink(.normal)
        count.textColor = chrome.ink(.muted)
        field.placeholderAttributedString = NSAttributedString(
            string: "Find in scrollback",
            attributes: [.foregroundColor: chrome.ink(.muted), .font: field.font ?? ChromeType.font(.small)])
    }
}

extension FindField: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
        refreshQueryFade()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        onFocusChange?(false)
    }

    /// An IME composition owns Return and Esc, so marked text never steps or closes the field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            guard !textView.hasMarkedText() else { return false }
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            onStep?(backwards ? .previous : .next)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard !textView.hasMarkedText() else { return false }
            onCancel?()
            return true
        default:
            return false
        }
    }
}

// `controlTextDidBeginEditing` waits for the first keystroke, so a click into the field reports here instead.
private final class FocusReportingField: NSTextField {
    var onFocus: (() -> Void)?
    var onEditorDetached: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocus?() }
        return took
    }

    // The delegate hears about the end of editing while the field editor is still attached.
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onEditorDetached?()
    }
}
