import AppKit

final class SegmentedControl: NSView {
    private(set) var selectedIndex: Int
    private(set) var optionTitles: [String]
    var onChange: (Int) -> Void
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            segments.forEach { $0.isEnabled = isEnabled }
            if !isEnabled, isControlFocused { window?.makeFirstResponder(nil) }
        }
    }

    private var segments: [AppButton] = []
    // Without an intrinsic width the control stretches to fill its row instead of hugging its segments.
    private var segmentsStack: NSStackView?
    // Lets a reselect pin a value that is only OS-derived, as the reduce-motion row needs.
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

    override var intrinsicContentSize: NSSize {
        guard let segmentsStack else { return super.intrinsicContentSize }
        return NSSize(width: segmentsStack.fittingSize.width, height: NSView.noIntrinsicMetric)
    }

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

    func setSelection(_ index: Int) {
        selectedIndex = min(max(index, 0), segments.count - 1)
        updateSelection()
    }

    private var isControlFocused = false

    func reapplyTheme() {
        segments.forEach { $0.reapplyTheme() }
    }

    private func updateSelection() {
        for (index, segment) in segments.enumerated() { segment.isOn = (index == selectedIndex) }
        refreshOutline()
    }

    override var acceptsFirstResponder: Bool { isEnabled }

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
        guard isEnabled else { return super.keyDown(with: event) }
        switch KeyboardFocus.key(for: event) {
        case .left where selectedIndex == 0 && onArrowLeft != nil: onArrowLeft?()
        case .left: select(selectedIndex - 1)
        case .right: select(selectedIndex + 1)
        case .up: onArrowUp?()
        case .down, .activate: onArrowDown?()
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    private func refreshOutline() {
        for (index, segment) in segments.enumerated() {
            segment.showsFocusOutline = isControlFocused && index == selectedIndex
        }
    }
}
