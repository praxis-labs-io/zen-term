import AppKit

/// Base for settings sections built from live-editing form rows: number-field / segmented / text /
/// custom editors over the chrome config. Each edit applies live via a `ConfigWriter` scalar write +
/// `AppConfig.reload()`, debounced so rapid typing coalesces into one write. A blank numeric field
/// removes the key so the value falls back to `builtIn` — the placeholder shows that default, and a
/// field renders blank while it's at the default. Subclasses only override `navTitle` and `populate()`
/// (declaring their groups/rows); the base owns the row builders, live-apply debounce, focus stops,
/// and Reset-all.
class SettingsFormSection: SettingsSection {
    var navTitle: String { "" }
    var onExitToNav: (() -> Void)?
    var onClose: (() -> Void)?

    private let resetAllButton = AppButton(title: "Reset all to defaults", variant: .muted)
    private let resetAllMessage = ResetFlashLabel()
    private var rows: [LayoutRow] = []
    private var stops: [NSView] = []  // ordered vertical focus stops: each row's control + Reset-all
    private var controlForKey: [String: NSView] = [:]
    private var scalarKeys: [String] = []  // every key this section owns (for Reset-all)
    private var refreshers: [() -> Void] = []  // per-row "sync me to the reloaded config" closures
    private var integerKeys: Set<String> = []  // numeric rows that commit whole numbers (e.g. counts)

    /// Live-apply debounce: a field edit schedules its write ~`applyDelay` later; rapid typing
    /// coalesces into one write + reload + relayout. Blur/Return flush it immediately.
    private var pendingApply: (() -> Void)?
    private var applyTimer: DispatchWorkItem?
    private let applyDelay: TimeInterval = 0.18

    // Build-time cursors, valid only while `makeDetailView` -> `populate` is running.
    private var rowsStack: NSStackView?
    private var lastArranged: NSView?

    func makeDetailView() -> NSView {
        rows = []
        stops = []
        controlForKey = [:]
        scalarKeys = []
        refreshers = []
        integerKeys = []
        lastArranged = nil

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10  // rows don't touch vertically
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack = stack

        populate()

        resetAllButton.isKeyboardFocusable = true
        resetAllButton.onArrowUp = { [weak self] in self?.moveFocus(-1) }
        resetAllButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        resetAllButton.onEsc = { [weak self] in self?.onClose?() }
        resetAllButton.onTap = { [weak self] in self?.resetAll() }
        stack.addArrangedSubview(resetAllButton)
        if let lastArranged { stack.setCustomSpacing(20, after: lastArranged) }  // gap before Reset all
        stops.append(resetAllButton)

        stack.addArrangedSubview(resetAllMessage)
        stack.setCustomSpacing(6, after: resetAllButton)  // tuck the success line under the button

        let scroll = SettingsDetail.scroll(for: stack)
        refreshRows()
        return scroll
    }

    func detailStops() -> [NSView] { stops.filter { !$0.isHidden } }

    /// Subclass hook: declare the section's groups and rows here (via `addGroup` + the row builders).
    func populate() {}

    // MARK: groups

    /// Open a titled group: a small caption, a 20pt gap above it, then the rows added inside `build`.
    func addGroup(_ title: String, _ build: () -> Void) {
        guard let stack = rowsStack else { return }
        let caption = NSTextField(labelWithString: title.uppercased())
        caption.font = .systemFont(ofSize: 10, weight: .semibold)
        caption.textColor = Theme.current.chrome.ink(alpha: 0.4)
        stack.addArrangedSubview(caption)
        if let lastArranged { stack.setCustomSpacing(20, after: lastArranged) }  // gap between groups
        build()
        lastArranged = stack.arrangedSubviews.last
    }

    // MARK: row builders

    /// A numeric (CGFloat) knob. `read(GeneralConfig.builtIn)` is the placeholder + blank-state
    /// default; the row's subtext is the blurb plus the range. Blank = default (the key is removed).
    func addNumericRow(
        key: String, caption: String, blurb: String, range: ClosedRange<CGFloat>,
        read: @escaping (GeneralConfig) -> CGFloat, width: CGFloat = 64, integer: Bool = false
    ) {
        scalarKeys.append(key)
        if integer { integerKeys.insert(key) }
        let box = FieldBox(placeholder: LayoutFormat.number(read(GeneralConfig.builtIn)))
        box.field.alignment = .right  // numbers read right-aligned; shell/path fields stay left
        box.setText(fieldText(for: read))
        box.onChange = { [weak self, weak box] in
            guard let self, let box else { return }
            let text = box.text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                // Blank = default, but don't live-apply the removal mid-edit — clearing the field to
                // retype it would otherwise snap every window to the built-in value on the debounce
                // tick. Stage the blank so blur/Return still commits it, and cancel any pending write.
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
                self.applyTimer?.cancel()  // never apply an invalid value
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

    /// A segmented picker over `options`. `read` maps the live config to the selected index; `token`
    /// maps a picked index to the config token to write. `notifiesOnReselect` lets re-picking the
    /// already-shown value still write (used to pin an OS-derived default).
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

    /// A free-text field. `read` supplies the current value; edits write the trimmed text, or remove
    /// the key when blank. Left-aligned (paths / shell fields).
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

    /// A caller-owned control (e.g. the Theme dropdown): the caller supplies the control, its focus
    /// stop, and a `refresh` closure to re-sync it on reload; the base just registers it.
    func addCustomRow(
        key: String, caption: String, description: String?, control: NSView, focusStop: NSView,
        controlNote: String?, width: CGFloat?, refresh: @escaping () -> Void
    ) {
        addRow(
            key: key, caption: caption, description: description, control: control, focusStop: focusStop,
            controlNote: controlNote, width: width, refresh: refresh)
    }

    /// Append an arranged subview to the rows stack directly. Pass `focusStop` to also register it
    /// as a vertical focus stop (its keyboard wired like any other control) — e.g. the restart
    /// button tucked under the Theme row, which starts hidden and is skipped by `moveFocus` /
    /// `detailStops()` until it's shown. Omit `focusStop` for a purely decorative trailing view.
    func appendTrailing(_ view: NSView, focusStop: NSView? = nil) {
        guard let stack = rowsStack else { return }
        stack.addArrangedSubview(view)
        if let focusStop {
            wireControlKeyboard(focusStop)
            stops.append(focusStop)
        }
    }

    /// Register a row. `focusStop` is the actual first-responder-focusable view (a `FieldBox`'s inner
    /// `field`, or the control itself for a `SegmentedControl`) — the wrapper `FieldBox` isn't
    /// focusable, so the stop must be its text field. `description` sits under the caption;
    /// `controlNote` (the range) sits under the input.
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

    /// Wire a control's Up/Down (move rows), Tab/⇧Tab (advance / return to nav), Left-at-boundary
    /// (nav), and Esc (close) through the section. There's no per-row reset stop — a blank field is
    /// the default — so Tab simply advances to the next control.
    private func wireControlKeyboard(_ control: NSView) {
        switch control {
        case let box as FieldBox:
            box.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            box.onArrowDown = { [weak self] in self?.moveFocus(1) }
            box.onArrowLeft = { [weak self] in self?.onExitToNav?() }  // Left at cursor-start → nav
            box.onTab = { [weak self] in self?.moveFocus(1) }
            box.onBacktab = { [weak self] in self?.onExitToNav?() }
            box.onEsc = { [weak self] in self?.onClose?() }
        case let seg as SegmentedControl:
            seg.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            seg.onArrowDown = { [weak self] in self?.moveFocus(1) }
            seg.onTab = { [weak self] in self?.moveFocus(1) }
            seg.onBacktab = { [weak self] in self?.onExitToNav?() }
            seg.onEsc = { [weak self] in self?.onClose?() }
        case let dropdown as Dropdown:
            dropdown.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            dropdown.onArrowDown = { [weak self] in self?.moveFocus(1) }
            dropdown.onTab = { [weak self] in self?.moveFocus(1) }
            dropdown.onBacktab = { [weak self] in self?.onExitToNav?() }
            dropdown.onEsc = { [weak self] in self?.onClose?() }
        case let button as AppButton:
            button.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            button.onArrowDown = { [weak self] in self?.moveFocus(1) }
            button.onArrowLeft = { [weak self] in self?.onExitToNav?() }
            button.onEsc = { [weak self] in self?.onClose?() }
        default:
            break
        }
    }

    // MARK: writes

    /// Commit a numeric field's value: write the canonical form, or remove the key when it's blank
    /// (blank = default). Invalid text never reaches here (the debounce is skipped while invalid).
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

    /// Run a write, reload, and refresh every row from the new config; returns whether it succeeded.
    /// On failure, report on the edited row — there's no staged state here (unlike keybinds).
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

    /// Sync every control to the reloaded config (each row registered its own refresh closure). A
    /// numeric/text field being edited skips itself so a live-apply write doesn't clobber the caret.
    private func refreshRows() {
        refreshers.forEach { $0() }
    }

    // MARK: debounce

    private func scheduleApply(_ block: @escaping () -> Void) {
        pendingApply = block
        applyTimer?.cancel()
        let token = DispatchWorkItem { [weak self] in self?.runPending() }
        applyTimer = token
        DispatchQueue.main.asyncAfter(deadline: .now() + applyDelay, execute: token)
    }

    /// Apply a pending edit immediately (Return/blur) instead of waiting out the debounce.
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

    // MARK: helpers

    /// A numeric field's text: the value when it differs from the default, else blank (the
    /// placeholder shows the default, and blank means "use the default").
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

    /// Move focus between the vertical stops that are currently visible — a hidden stop (e.g. the
    /// restart button before a theme change reveals it) is transparently skipped. Finds the current
    /// stop by which one is first responder (a stop may be a `FieldBox`'s field editor, so this is
    /// more robust than a passed-in view).
    private func moveFocus(_ delta: Int) {
        let visible = stops.filter { !$0.isHidden }
        let window = visible.first?.window
        let anchor = visible.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        guard let next = KeyboardFocus.step(from: anchor, delta: delta, count: visible.count) else { return }
        let target = visible[next]
        target.window?.makeFirstResponder(target)
        let scrollTarget = rows.first { target.isDescendant(of: $0) } ?? target
        scrollTarget.scrollToVisible(scrollTarget.bounds.insetBy(dx: 0, dy: -12))
    }

    private func rowFor(_ key: String) -> LayoutRow? {
        guard let control = controlForKey[key] else { return nil }
        return rows.first { control.isDescendant(of: $0) }
    }
}
