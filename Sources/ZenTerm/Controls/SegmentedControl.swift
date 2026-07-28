import AppKit

/// A keyboard-navigable horizontal segmented control: pick one of several labeled options. A
/// focus stop in a form's keyboard flow — Left/Right cycle the selection, Up/Down bubble to the
/// form (via `onArrowUp`/`onArrowDown`) to move between fields, Return/Down advance. Draws an
/// accent ring while it's first responder. Built from `AppButton` segments (mouse-clickable);
/// the container owns the keyboard.
final class SegmentedControl: NSView {
    private(set) var selectedIndex: Int
    /// The segment titles, in order — lets a caller find one of a form's several segmented controls
    /// without depending on view-tree order.
    private(set) var optionTitles: [String]
    var onChange: (Int) -> Void
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    /// Left at the leftmost segment (there's nowhere further left to cycle) exits the control — the
    /// form wires it to return to the nav, mirroring `FieldBox`'s Left-at-cursor-start. Left anywhere
    /// else still cycles the selection.
    var onArrowLeft: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    private var segments: [AppButton] = []
    /// The segment row, kept so `intrinsicContentSize` can report the content width — without an
    /// intrinsic size, content hugging has nothing to bite on and the control stretches to fill its
    /// row (leaving the segments floating left) instead of hugging its content and aligning right.
    private var segmentsStack: NSStackView?
    /// When true, re-picking the already-selected segment still fires `onChange`. Off by default;
    /// the reduce-motion row opts in so clicking the currently-shown (OS-derived `system`) value can
    /// pin it — otherwise a no-op click leaves config unpinned and it silently follows the OS later.
    private let notifiesOnReselect: Bool

    init(
        options: [String], selectedIndex: Int = 0, notifiesOnReselect: Bool = false,
        onChange: @escaping (Int) -> Void
    ) {
        self.optionTitles = options
        self.selectedIndex = selectedIndex
        self.notifiesOnReselect = notifiesOnReselect
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        segments = options.enumerated().map { index, title in
            AppButton(title: title, variant: .segment) { [weak self] in self?.select(index) }
        }
        let stack = NSStackView(views: segments)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        segmentsStack = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Report the segment row's width so content hugging can keep the control at its content size
    /// (and let a form's spacer push it to the trailing edge).
    override var intrinsicContentSize: NSSize {
        guard let segmentsStack else { return super.intrinsicContentSize }
        return NSSize(width: segmentsStack.fittingSize.width, height: NSView.noIntrinsicMetric)
    }

    /// Select an option (clamped), update the fill, and notify — used by both clicks and arrows.
    func select(_ index: Int) {
        let clamped = min(max(index, 0), segments.count - 1)
        guard notifiesOnReselect || clamped != selectedIndex || !segments[clamped].isOn else {
            selectedIndex = clamped
            updateSelection()
            return
        }
        selectedIndex = clamped
        updateSelection()
        onChange(clamped)
    }

    /// Set the selection WITHOUT firing `onChange` — for programmatic sync (e.g. after a config
    /// reload) where the change didn't originate from the user.
    func setSelection(_ index: Int) {
        selectedIndex = min(max(index, 0), segments.count - 1)
        updateSelection()
    }

    private var isControlFocused = false

    /// Re-apply the live chrome colors after a config change — no relaunch. All color lives on
    /// the `AppButton` segments; this control's own layer never carries color.
    func reapplyTheme() {
        segments.forEach { $0.reapplyTheme() }
    }

    private func updateSelection() {
        for (index, segment) in segments.enumerated() { segment.isOn = (index == selectedIndex) }
        refreshOutline()
    }

    // MARK: keyboard

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        isControlFocused = true
        refreshOutline()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isControlFocused = false
        refreshOutline()
        return true
    }

    override func drawFocusRingMask() {}  // the selected segment's accent outline marks focus

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .left where selectedIndex == 0 && onArrowLeft != nil: onArrowLeft?()  // boundary → exit
        case .left: select(selectedIndex - 1)
        case .right: select(selectedIndex + 1)
        case .up: onArrowUp?()  // previous field
        case .down, .activate: onArrowDown?()  // down / return / enter / space → next field
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()  // ⇧tab / tab
        default: super.keyDown(with: event)
        }
    }

    /// While focused, outline the selected segment (rather than filling the whole container).
    private func refreshOutline() {
        for (index, segment) in segments.enumerated() {
            segment.showsFocusOutline = isControlFocused && index == selectedIndex
        }
    }
}
