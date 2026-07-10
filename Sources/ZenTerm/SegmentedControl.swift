import AppKit

/// A keyboard-navigable horizontal segmented control: pick one of several labeled options. A
/// focus stop in a form's keyboard flow — Left/Right cycle the selection, Up/Down bubble to the
/// form (via `onArrowUp`/`onArrowDown`) to move between fields, Return/Down advance. Draws an
/// accent ring while it's first responder. Built from `AppButton` segments (mouse-clickable);
/// the container owns the keyboard.
final class SegmentedControl: NSView {
    private(set) var selectedIndex: Int
    var onChange: (Int) -> Void
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?

    private var segments: [AppButton] = []

    init(options: [String], selectedIndex: Int = 0, onChange: @escaping (Int) -> Void) {
        self.selectedIndex = selectedIndex
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
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Select an option (clamped), update the fill, and notify — used by both clicks and arrows.
    func select(_ index: Int) {
        let clamped = min(max(index, 0), segments.count - 1)
        guard clamped != selectedIndex || !segments[clamped].isOn else {
            selectedIndex = clamped
            updateSelection()
            return
        }
        selectedIndex = clamped
        updateSelection()
        onChange(clamped)
    }

    private var isControlFocused = false

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
        switch event.keyCode {
        case 123: select(selectedIndex - 1)  // left
        case 124: select(selectedIndex + 1)  // right
        case 126: onArrowUp?()  // up → previous field
        case 125, 36, 76: onArrowDown?()  // down / return / enter → next field
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
