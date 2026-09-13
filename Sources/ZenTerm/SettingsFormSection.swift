import AppKit

protocol ThemeReapplying: AnyObject {
    func reapplyTheme()
}
extension FieldBox: ThemeReapplying {}
extension TextAreaBox: ThemeReapplying {}
extension Dropdown: ThemeReapplying {}
extension SegmentedControl: ThemeReapplying {}
extension AppButton: ThemeReapplying {}
extension CheckboxDropdown: ThemeReapplying {}

class SettingsFormSection: SettingsSection {
    var navTitle: String { "" }
    var onExitToNav: (() -> Void)?

    private let resetAllButton = AppButton(title: "Reset all to defaults", variant: .muted)
    private let resetAllMessage = ResetFlashLabel()
    private var rows: [LayoutRow] = []
    private var groupCaptions: [NSTextField] = []
    private var stops: [NSView] = []
    private var controlForKey: [String: NSView] = [:]
    private var scalarKeys: [String] = []
    private var refreshers: [() -> Void] = []
    private var integerKeys: Set<String> = []

    private var pendingApply: (() -> Void)?
    private var applyTimer: DispatchWorkItem?
    private let applyDelay: TimeInterval = 0.18

    private var rowsStack: NSStackView?
    private var lastArranged: NSView?

    func makeDetailView() -> NSView {
        rows = []
        groupCaptions = []
        stops = []
        controlForKey = [:]
        scalarKeys = []
        refreshers = []
        integerKeys = []
        lastArranged = nil

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack = stack

        populate()

        resetAllButton.isKeyboardFocusable = true
        resetAllButton.onArrowUp = { [weak self] in self?.moveFocus(-1) }
        resetAllButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        resetAllButton.onTab = { [weak self] in self?.moveTab(1) }
        resetAllButton.onBacktab = { [weak self] in self?.moveTab(-1) }
        resetAllButton.onTap = { [weak self] in self?.resetAll() }
        let resetRow = SettingsDetail.trailingRow(resetAllButton)
        stack.addArrangedSubview(resetRow)
        resetRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let lastArranged { stack.setCustomSpacing(20, after: lastArranged) }
        stops.append(resetAllButton)

        let messageRow = SettingsDetail.trailingRow(resetAllMessage)
        stack.addArrangedSubview(messageRow)
        messageRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(6, after: resetRow)

        let scroll = SettingsDetail.scroll(for: stack)
        refreshRows()
        return scroll
    }

    func detailStops() -> [NSView] { stops.filter { !$0.isHidden } }

    func reapplyTheme() {
        groupCaptions.forEach { $0.textColor = Theme.current.chrome.ink(.muted) }
        rows.forEach { $0.reapplyTheme() }
        controlForKey.values.compactMap { $0 as? ThemeReapplying }.forEach { $0.reapplyTheme() }
        resetAllButton.reapplyTheme()
        resetAllMessage.reapplyTheme()
    }

    func populate() {}

    func addGroup(_ title: String, _ build: () -> Void) {
        guard let stack = rowsStack else { return }
        let caption = SettingsDetail.groupCaption(title)
        stack.addArrangedSubview(caption)
        groupCaptions.append(caption)
        if let lastArranged { stack.setCustomSpacing(20, after: lastArranged) }
        build()
        lastArranged = stack.arrangedSubviews.last
    }

    func addNumericRow(
        key: String, caption: String, blurb: String, range: ClosedRange<CGFloat>,
        read: @escaping (GeneralConfig) -> CGFloat, width: CGFloat = 64, integer: Bool = false
    ) {
        scalarKeys.append(key)
        if integer { integerKeys.insert(key) }
        let box = FieldBox(placeholder: LayoutFormat.number(read(GeneralConfig.builtIn)))
        box.field.alignment = .right
        box.setText(fieldText(for: read))
        box.onChange = { [weak self, weak box] in
            guard let self, let box else { return }
            let text = box.text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                self.rowFor(key)?.showMessage(nil)
                self.applyTimer?.cancel()
                self.pendingApply = { [weak self, weak box] in
                    guard let self, let box else { return }
                    self.commitNumeric(key: key, range: range, box: box)
                }
                return
            }
            let isValid = LayoutFormat.parseNumber(text, in: range) != nil
            self.rowFor(key)?.showMessage(isValid ? nil : self.rangeMessage(range))
            if isValid {
                self.scheduleApply { [weak self, weak box] in
                    guard let self, let box else { return }
                    self.commitNumeric(key: key, range: range, box: box)
                }
            } else {
                self.applyTimer?.cancel()
            }
        }
        box.onEndEditing = { [weak self] in self?.flushApply() }
        addRow(
            key: key, caption: caption, description: blurb, control: box, focusStop: box.field,
            controlNote: rangeText(range), width: width,
            refresh: { [weak self, weak box] in
                guard let self, let box, box.field.currentEditor() == nil else { return }
                box.setText(self.fieldText(for: read))
            })
    }

    func addSegmentedRow(
        key: String, caption: String, blurb: String?, options: [String],
        read: @escaping (GeneralConfig) -> Int, token: @escaping (Int) -> String,
        notifiesOnReselect: Bool = false
    ) {
        scalarKeys.append(key)
        let segmented = SegmentedControl(
            options: options, selectedIndex: read(GeneralConfig.current), notifiesOnReselect: notifiesOnReselect
        ) { [weak self] index in
            self?.writeOrRemove(key, token(index), row: key)
        }
        addRow(
            key: key, caption: caption, description: blurb, control: segmented, focusStop: segmented,
            controlNote: nil, width: nil,
            refresh: { [weak segmented] in segmented?.setSelection(read(GeneralConfig.current)) })
    }

    func addTextRow(
        key: String, caption: String, blurb: String?, placeholder: String,
        read: @escaping (GeneralConfig) -> String, width: CGFloat = 200
    ) {
        scalarKeys.append(key)
        let box = FieldBox(placeholder: placeholder)
        box.setText(read(GeneralConfig.current))
        box.onChange = { [weak self, weak box] in
            guard let self, let box else { return }
            self.scheduleApply { [weak self, weak box] in
                guard let self, let box else { return }
                let text = box.text.trimmingCharacters(in: .whitespaces)
                self.writeOrRemove(key, text.isEmpty ? nil : text, row: key)
            }
        }
        box.onEndEditing = { [weak self] in self?.flushApply() }
        addRow(
            key: key, caption: caption, description: blurb, control: box, focusStop: box.field,
            controlNote: nil, width: width,
            refresh: { [weak box] in
                guard let box, box.field.currentEditor() == nil else { return }
                box.setText(read(GeneralConfig.current))
            })
    }

    /// Opt-in: theme and accent rows resolve keys through their catalogs, and registering them would widen Reset-all.
    func registerScalarKey(_ key: String) {
        scalarKeys.append(key)
    }

    func addCustomRow(
        key: String, caption: String, description: String?, control: NSView, focusStop: NSView,
        controlNote: String?, width: CGFloat?, refresh: @escaping () -> Void
    ) {
        addRow(
            key: key, caption: caption, description: description, control: control, focusStop: focusStop,
            controlNote: controlNote, width: width, refresh: refresh)
    }

    private func addRow(
        key: String, caption: String, description: String?, control: NSView, focusStop: NSView,
        controlNote: String?, width: CGFloat?, refresh: @escaping () -> Void
    ) {
        guard let stack = rowsStack else { return }
        let row = LayoutRow(
            caption: caption, description: description, control: control, controlNote: controlNote,
            controlWidth: width)
        wireControlKeyboard(control)
        rows.append(row)
        stops.append(focusStop)
        controlForKey[key] = control
        refreshers.append(refresh)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func wireControlKeyboard(_ control: NSView) {
        switch control {
        case let box as FieldBox:
            box.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            box.onArrowDown = { [weak self] in self?.moveFocus(1) }
            box.onArrowLeft = { [weak self] in self?.onExitToNav?() }
            box.onTab = { [weak self] in self?.moveTab(1) }
            box.onBacktab = { [weak self] in self?.moveTab(-1) }
        case let seg as SegmentedControl:
            seg.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            seg.onArrowDown = { [weak self] in self?.moveFocus(1) }
            seg.onArrowLeft = { [weak self] in self?.onExitToNav?() }
            seg.onTab = { [weak self] in self?.moveTab(1) }
            seg.onBacktab = { [weak self] in self?.moveTab(-1) }
        case let dropdown as Dropdown:
            dropdown.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            dropdown.onArrowDown = { [weak self] in self?.moveFocus(1) }
            dropdown.onArrowLeft = { [weak self] in self?.onExitToNav?() }
            dropdown.onTab = { [weak self] in self?.moveTab(1) }
            dropdown.onBacktab = { [weak self] in self?.moveTab(-1) }
        case let button as AppButton:
            button.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            button.onArrowDown = { [weak self] in self?.moveFocus(1) }
            button.onArrowLeft = { [weak self] in self?.onExitToNav?() }
            button.onTab = { [weak self] in self?.moveTab(1) }
            button.onBacktab = { [weak self] in self?.moveTab(-1) }
        case let list as CheckboxDropdown:
            list.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            list.onArrowDown = { [weak self] in self?.moveFocus(1) }
            list.onArrowLeft = { [weak self] in self?.onExitToNav?() }
            list.onTab = { [weak self] in self?.moveTab(1) }
            list.onBacktab = { [weak self] in self?.moveTab(-1) }
        default:
            break
        }
    }

    private func commitNumeric(key: String, range: ClosedRange<CGFloat>, box: FieldBox) {
        let text = box.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            writeOrRemove(key, nil, row: key)
            return
        }
        guard var value = LayoutFormat.parseNumber(text, in: range) else { return }
        if integerKeys.contains(key) { value = value.rounded() }
        write(key, LayoutFormat.number(value), row: key)
    }

    func write(_ key: String, _ value: String, row: String) {
        persist({ try ConfigWriter.apply(scalars: [key: value]) }, reportKey: row)
    }
    func writeOrRemove(_ key: String, _ value: String?, row: String) {
        if let value {
            write(key, value, row: row)
        } else {
            persist({ try ConfigWriter.apply(removals: [key]) }, reportKey: row)
        }
    }
    private func resetAll() {
        guard persist({ try ConfigWriter.apply(removals: Set(self.scalarKeys)) }, reportKey: nil) else { return }
        resetAllMessage.flash("Defaults restored.")
    }

    @discardableResult
    private func persist(_ write: () throws -> Void, reportKey: String?) -> Bool {
        do {
            try write()
        } catch {
            (reportKey.flatMap(rowFor) ?? rows.first)?.showMessage(
                "Couldn't write config: \(error.localizedDescription)")
            return false
        }
        AppConfig.reload()
        refreshRows()
        return true
    }

    /// Skips a row showing a `.failure`: an unrelated write does not resolve what the user just did.
    private func refreshRows() {
        refreshers.forEach { $0() }
        let diagnostics = GeneralConfig.current.configDiagnostics
        for key in scalarKeys {
            guard let row = rowFor(key), row.messageKind != .failure else { continue }
            row.showMessage(diagnostics.first { $0.scope == .setting(key: key) }?.message, kind: .diagnostic)
        }
    }

    private func scheduleApply(_ block: @escaping () -> Void) {
        pendingApply = block
        applyTimer?.cancel()
        let token = DispatchWorkItem { [weak self] in self?.runPending() }
        applyTimer = token
        DispatchQueue.main.asyncAfter(deadline: .now() + applyDelay, execute: token)
    }

    private func flushApply() {
        applyTimer?.cancel()
        runPending()
    }

    private func runPending() {
        applyTimer = nil
        let block = pendingApply
        pendingApply = nil
        block?()
    }

    private func fieldText(for read: (GeneralConfig) -> CGFloat) -> String {
        let current = read(GeneralConfig.current)
        return current != read(GeneralConfig.builtIn) ? LayoutFormat.number(current) : ""
    }

    private func rangeMessage(_ range: ClosedRange<CGFloat>) -> String {
        "Enter a number in \(rangeText(range))."
    }

    private func rangeText(_ range: ClosedRange<CGFloat>) -> String {
        "\(LayoutFormat.number(range.lowerBound))–\(LayoutFormat.number(range.upperBound))"
    }

    private func moveFocus(_ delta: Int) {
        let visible = stops.filter { !$0.isHidden }
        let window = visible.first?.window
        let anchor = visible.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        SettingsDetail.moveFocus(stops: visible, from: anchor, delta: delta) { [rows] target in
            rows.first { target.isDescendant(of: $0) } ?? target
        }
    }

    private func moveTab(_ delta: Int) {
        let visible = stops.filter { !$0.isHidden }
        let window = visible.first?.window
        let anchor = visible.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        if delta < 0, anchor == 0 {
            onExitToNav?()
            return
        }
        SettingsDetail.moveFocus(stops: visible, from: anchor, delta: delta, wrap: true) { [rows] target in
            rows.first { target.isDescendant(of: $0) } ?? target
        }
    }

    private func rowFor(_ key: String) -> LayoutRow? {
        guard let control = controlForKey[key] else { return nil }
        return rows.first { control.isDescendant(of: $0) }
    }

    #if DEBUG
        func controlForTesting(_ key: String) -> NSView? { controlForKey[key] }
    #endif
}
