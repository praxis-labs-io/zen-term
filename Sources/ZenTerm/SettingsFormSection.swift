import AppKit

/// A form control that can re-apply its own theme colors — lets `SettingsFormSection` recolor
/// whatever `controlForKey` happens to be holding (a `FieldBox`, `Dropdown`, or `SegmentedControl`)
/// without a type-switch, and lets `AddWorkspaceOverlay` (ZEN-89 task 8) recolor its own mixed
/// bag of controls (`FieldBox`, `SegmentedControl`, `AppButton`) the same way. Conformance is
/// declared where each control already defines its own `reapplyTheme()` (Task 6); this file just
/// groups them so a heterogeneous collection can be filtered/iterated by protocol.
protocol ThemeReapplying: AnyObject {
    func reapplyTheme()
}
extension FieldBox: ThemeReapplying {}
extension TextAreaBox: ThemeReapplying {}
extension Dropdown: ThemeReapplying {}
extension SegmentedControl: ThemeReapplying {}
extension AppButton: ThemeReapplying {}
extension CheckboxList: ThemeReapplying {}

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

    private let resetAllButton = AppButton(title: "Reset all to defaults", variant: .muted)
    private let resetAllMessage = ResetFlashLabel()
    private var rows: [LayoutRow] = []
    /// Retained (not throwaway locals) so `reapplyTheme()` can recolor them in place — see
    /// `addGroup`.
    private var groupCaptions: [NSTextField] = []
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
        stack.spacing = 10  // rows don't touch vertically
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
        if let lastArranged { stack.setCustomSpacing(20, after: lastArranged) }  // gap before Reset all
        stops.append(resetAllButton)

        let messageRow = SettingsDetail.trailingRow(resetAllMessage)
        stack.addArrangedSubview(messageRow)
        messageRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(6, after: resetRow)  // tuck the success line under the button

        let scroll = SettingsDetail.scroll(for: stack)
        refreshRows()
        return scroll
    }

    func detailStops() -> [NSView] { stops.filter { !$0.isHidden } }

    /// Re-apply the section's theme-dependent colors IN PLACE — no rebuild, so this never routes
    /// through `makeDetailView()`/`selectSection` and never triggers `sectionWillHide()`. Recolors
    /// every group caption, every row (caption/description/control-note/message), every registered
    /// control (`FieldBox`/`Dropdown`/`SegmentedControl`, whichever `controlForKey` is holding), and
    /// the persistent Reset-all button + its flash message — the two views that were previously only
    /// re-parented (never recolored) by a rebuild.
    func reapplyTheme() {
        groupCaptions.forEach { $0.textColor = Theme.current.chrome.ink(alpha: 0.4) }
        rows.forEach { $0.reapplyTheme() }
        controlForKey.values.compactMap { $0 as? ThemeReapplying }.forEach { $0.reapplyTheme() }
        resetAllButton.reapplyTheme()
        resetAllMessage.reapplyTheme()
    }

    /// Subclass hook: declare the section's groups and rows here (via `addGroup` + the row builders).
    func populate() {}

    // MARK: groups

    /// Open a titled group: a small caption, a 20pt gap above it, then the rows added inside `build`.
    func addGroup(_ title: String, _ build: () -> Void) {
        guard let stack = rowsStack else { return }
        let caption = SettingsDetail.groupCaption(title)
        stack.addArrangedSubview(caption)
        groupCaptions.append(caption)
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

    /// Register a custom row's config key with the shared key services: Reset-all removes it, and
    /// `refreshRows()` surfaces its file diagnostics on the row. `addCustomRow` deliberately doesn't
    /// do this itself — theme/accent rows resolve their keys through their own catalogs and opting
    /// them in would change what Reset-all touches — so a scalar-backed custom row opts in here.
    func registerScalarKey(_ key: String) {
        scalarKeys.append(key)
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

    /// Wire a control's Up/Down (move rows), Tab/⇧Tab (advance / retreat), and Left-at-boundary
    /// (nav) through the section. There's no per-row reset stop — a blank field is the default — so
    /// Tab simply advances to the next control. Esc belongs to the card root (see `ModalEscape`).
    private func wireControlKeyboard(_ control: NSView) {
        switch control {
        case let box as FieldBox:
            box.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            box.onArrowDown = { [weak self] in self?.moveFocus(1) }
            box.onArrowLeft = { [weak self] in self?.onExitToNav?() }  // Left at cursor-start → nav
            box.onTab = { [weak self] in self?.moveTab(1) }
            box.onBacktab = { [weak self] in self?.moveTab(-1) }
        case let seg as SegmentedControl:
            seg.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            seg.onArrowDown = { [weak self] in self?.moveFocus(1) }
            seg.onArrowLeft = { [weak self] in self?.onExitToNav?() }  // Left at the leftmost segment → nav
            seg.onTab = { [weak self] in self?.moveTab(1) }
            seg.onBacktab = { [weak self] in self?.moveTab(-1) }
        case let dropdown as Dropdown:
            dropdown.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            dropdown.onArrowDown = { [weak self] in self?.moveFocus(1) }
            dropdown.onArrowLeft = { [weak self] in self?.onExitToNav?() }  // Left → nav (a dropdown owns no Left)
            dropdown.onTab = { [weak self] in self?.moveTab(1) }
            dropdown.onBacktab = { [weak self] in self?.moveTab(-1) }
        case let button as AppButton:
            button.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            button.onArrowDown = { [weak self] in self?.moveFocus(1) }
            button.onArrowLeft = { [weak self] in self?.onExitToNav?() }
            button.onTab = { [weak self] in self?.moveTab(1) }
            button.onBacktab = { [weak self] in self?.moveTab(-1) }
        case let list as CheckboxList:
            // The list bubbles Up/Down only at its boundary rows; in between they move its highlight.
            list.onArrowUp = { [weak self] in self?.moveFocus(-1) }
            list.onArrowDown = { [weak self] in self?.moveFocus(1) }
            list.onArrowLeft = { [weak self] in self?.onExitToNav?() }
            list.onTab = { [weak self] in self?.moveTab(1) }
            list.onBacktab = { [weak self] in self?.moveTab(-1) }
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

    /// Sync every control to the reloaded config (each row registered its own refresh closure), then
    /// surface any config-file diagnostic on the row that owns its key — the form analogue of the
    /// Keybinds section's per-row conflict note (ZEN-7). Runs on section open and after every
    /// in-section write; the reload toast is what announces a hand-edit made while this isn't open.
    ///
    /// Skips a row currently showing a `.failure` — a live invalid-range error, or a "Couldn't write
    /// config" — exactly as `SettingsKeybindsSection.refreshRows` does: those report something the
    /// user just did, which an unrelated write's refresh doesn't resolve, so clearing them here would
    /// wipe the feedback while it's still true.
    private func refreshRows() {
        refreshers.forEach { $0() }
        let diagnostics = GeneralConfig.current.configDiagnostics
        for key in scalarKeys {
            guard let row = rowFor(key), row.messageKind != .failure else { continue }
            row.showMessage(diagnostics.first { $0.scope == .setting(key: key) }?.message, kind: .diagnostic)
        }
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

    /// Move focus between the vertical stops that are currently visible — a hidden stop is
    /// transparently skipped. Finds the current stop by which one is first responder (a stop may be
    /// a `FieldBox`'s field editor, so this is more robust than a passed-in view).
    private func moveFocus(_ delta: Int) {
        let visible = stops.filter { !$0.isHidden }
        let window = visible.first?.window
        let anchor = visible.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        let moved = SettingsDetail.moveFocus(stops: visible, from: anchor, delta: delta) { [rows] target in
            rows.first { target.isDescendant(of: $0) } ?? target
        }
        // Up from the first stop has nowhere to go in the pane, so it returns to the nav rather than
        // dead-ending — the non-mutating way back for a section whose first stop is a segmented row.
        if !moved, delta < 0 { onExitToNav?() }
    }

    /// Tab traversal, which differs from the arrows at the ends: Tab wraps from the last stop back
    /// to the first (a Tab loop that stops dead reads as broken), and Shift-Tab retreats one stop,
    /// exiting to the nav only from the first — mirroring how Left exits.
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
}
