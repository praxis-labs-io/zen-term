import AppKit

/// The Layout & Motion settings section: number-field / segmented / text editors for the chrome
/// layout knobs, motion preference, and shell fields. Each edit applies live via a `ConfigWriter`
/// scalar write + `AppConfig.reload()`, debounced so rapid typing coalesces into one write. A blank
/// field removes the key so the value falls back to `builtIn` — the placeholder shows that default,
/// and a field renders blank while it's at the default. Live-appliable knobs update running windows
/// through the `configDidChange` seam; the rest apply to new tabs, labeled as such.
final class SettingsLayoutSection: SettingsSection {
    var navTitle: String { "General" }
    var onExitToNav: (() -> Void)?
    var onClose: (() -> Void)?

    /// A numeric (CGFloat) knob: config key, caption, a short `blurb` describing it, valid range, and
    /// how to read its value. `read(GeneralConfig.builtIn)` is the placeholder + blank-state default;
    /// the row's subtext is the blurb plus the range.
    private struct NumericKnob {
        let key: String
        let caption: String
        let blurb: String
        let range: ClosedRange<CGFloat>
        let read: (GeneralConfig) -> CGFloat
    }

    private static let numericKnobs: [(String, [NumericKnob])] = [
        (
            "Layout",
            [
                NumericKnob(
                    key: "backdrop-alpha", caption: "Backdrop alpha", blurb: "Tint strength over the window blur",
                    range: 0...1, read: { $0.backdropAlpha }),
                NumericKnob(
                    key: "window-gutter", caption: "Window gutter", blurb: "Space around the window edge",
                    range: 0...64, read: { $0.windowGutter }),
                NumericKnob(
                    key: "pane-gap", caption: "Pane gap", blurb: "Space between split panes",
                    range: 0...64, read: { $0.panelGap }),
                NumericKnob(
                    key: "bottom-drawer-fraction", caption: "Default bottom drawer height",
                    blurb: "Height it opens to (new tabs)", range: 0.1...0.9, read: { $0.bottomDrawerFraction }),
                NumericKnob(
                    key: "right-drawer-fraction", caption: "Default right drawer width",
                    blurb: "Width it opens to (new tabs)", range: 0.1...0.9, read: { $0.rightDrawerFraction }),
                NumericKnob(
                    key: "drawer-resize-step", caption: "Drawer resize step",
                    blurb: "How far each ⌥-arrow nudge resizes", range: 4...400, read: { $0.drawerResizeStep }),
                NumericKnob(
                    key: "max-drawer-fraction", caption: "Max drawer width/height",
                    blurb: "Largest a drawer can grow", range: 0.3...0.95, read: { $0.maxDrawerFraction }),
            ]
        )
    ]

    private let resetAllButton = AppButton(title: "Reset all to defaults", variant: .muted)
    private var rows: [LayoutRow] = []
    private var stops: [NSView] = []  // ordered vertical focus stops: each row's control + Reset-all
    private var controlForKey: [String: NSView] = [:]
    private var scalarKeys: [String] = []  // every key this section owns (for Reset-all)

    /// Live-apply debounce: a field edit schedules its write ~`applyDelay` later; rapid typing
    /// coalesces into one write + reload + relayout. Blur/Return flush it immediately.
    private var pendingApply: (() -> Void)?
    private var applyTimer: DispatchWorkItem?
    private let applyDelay: TimeInterval = 0.18

    func makeDetailView() -> NSView {
        rows = []
        stops = []
        controlForKey = [:]
        scalarKeys = []

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10  // rows don't touch vertically
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        var previous: NSView?
        func addGroup(_ title: String, _ build: (NSStackView) -> Void) {
            let caption = NSTextField(labelWithString: title.uppercased())
            caption.font = .systemFont(ofSize: 10, weight: .semibold)
            caption.textColor = Theme.current.chrome.ink(alpha: 0.4)
            rowsStack.addArrangedSubview(caption)
            if let previous { rowsStack.setCustomSpacing(20, after: previous) }  // gap between groups
            build(rowsStack)
            previous = rowsStack.arrangedSubviews.last
        }

        for (groupTitle, knobs) in Self.numericKnobs {
            addGroup(groupTitle) { stack in for knob in knobs { self.addNumericRow(knob, to: stack) } }
        }
        addGroup("Motion") { stack in self.addReduceMotionRow(to: stack) }
        addGroup("Shell") { stack in self.addShellRows(to: stack) }

        resetAllButton.isKeyboardFocusable = true
        resetAllButton.onArrowUp = { [weak self] in self?.moveFocus(-1) }
        resetAllButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        resetAllButton.onEsc = { [weak self] in self?.onClose?() }
        resetAllButton.onTap = { [weak self] in self?.resetAll() }
        rowsStack.addArrangedSubview(resetAllButton)
        if let previous { rowsStack.setCustomSpacing(20, after: previous) }  // gap before Reset all
        stops.append(resetAllButton)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = SlimScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 18),
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -18),
        ])
        refreshRows()
        return scroll
    }

    func detailStops() -> [NSView] { stops }

    // MARK: row builders

    private func addNumericRow(_ knob: NumericKnob, to stack: NSStackView) {
        scalarKeys.append(knob.key)
        let box = FieldBox(placeholder: LayoutFormat.number(knob.read(GeneralConfig.builtIn)))
        box.field.alignment = .right  // numbers read right-aligned; shell/path fields stay left
        box.setText(fieldText(for: knob))
        box.onChange = { [weak self, weak box] in
            guard let self, let box else { return }
            let text = box.text.trimmingCharacters(in: .whitespaces)
            let isValid = text.isEmpty || LayoutFormat.parseNumber(text, in: knob.range) != nil
            self.rowFor(knob.key)?.showMessage(isValid ? nil : self.rangeMessage(knob))
            if isValid {
                self.scheduleApply { [weak self, weak box] in
                    guard let self, let box else { return }
                    self.commitNumeric(knob, box: box)
                }
            } else {
                self.applyTimer?.cancel()  // never apply an invalid value
            }
        }
        box.onEndEditing = { [weak self] in self?.flushApply() }
        addRow(
            key: knob.key, caption: knob.caption, description: knob.blurb, control: box, focusStop: box.field,
            controlNote: rangeText(knob), width: 64, to: stack)
    }

    private func addReduceMotionRow(to stack: NSStackView) {
        scalarKeys.append("reduce-motion")
        // On/Off only. The config's `system` default follows the OS accessibility setting; with no
        // System segment we resolve it to show the effective initial state, and picking On/Off pins
        // reduce-motion regardless of the OS.
        let segmented = SegmentedControl(options: ["On", "Off"], selectedIndex: reduceMotionIsOn() ? 0 : 1) {
            [weak self] index in
            self?.writeOrRemove(
                "reduce-motion", LayoutFormat.reduceMotionToken(index == 0 ? .on : .off), row: "reduce-motion")
        }
        addRow(
            key: "reduce-motion", caption: "Reduce motion", description: nil, control: segmented,
            focusStop: segmented, controlNote: nil, width: nil, to: stack)
    }

    /// Whether reduce-motion is currently effective: an explicit on/off wins; `system` follows the
    /// OS accessibility setting (there's no System segment, so it's resolved for the initial state).
    private func reduceMotionIsOn() -> Bool {
        switch GeneralConfig.current.reduceMotion {
        case .on: return true
        case .off: return false
        case .system: return Motion.isReduceMotionEnabled()
        }
    }

    private func addShellRows(to stack: NSStackView) {
        scalarKeys.append(contentsOf: ["shell", "shell-args"])
        let shellBox = FieldBox(placeholder: "login shell")
        shellBox.setText(GeneralConfig.current.shell ?? "")
        shellBox.onChange = { [weak self, weak shellBox] in
            guard let self, let shellBox else { return }
            self.scheduleApply { [weak self, weak shellBox] in
                guard let self, let shellBox else { return }
                let text = shellBox.text.trimmingCharacters(in: .whitespaces)
                self.writeOrRemove("shell", text.isEmpty ? nil : text, row: "shell")
            }
        }
        shellBox.onEndEditing = { [weak self] in self?.flushApply() }
        addRow(
            key: "shell", caption: "Shell", description: "new tabs", control: shellBox, focusStop: shellBox.field,
            controlNote: nil, width: 200, to: stack)

        let argsBox = FieldBox(placeholder: "—")
        argsBox.setText(LayoutFormat.joinArgs(GeneralConfig.current.shellArgs))
        argsBox.onChange = { [weak self, weak argsBox] in
            guard let self, let argsBox else { return }
            self.scheduleApply { [weak self, weak argsBox] in
                guard let self, let argsBox else { return }
                let joined = LayoutFormat.joinArgs(LayoutFormat.splitArgs(argsBox.text))
                self.writeOrRemove("shell-args", joined.isEmpty ? nil : joined, row: "shell-args")
            }
        }
        argsBox.onEndEditing = { [weak self] in self?.flushApply() }
        addRow(
            key: "shell-args", caption: "Shell args", description: "new tabs", control: argsBox,
            focusStop: argsBox.field, controlNote: nil, width: 200, to: stack)
    }

    /// Add a row. `focusStop` is the actual first-responder-focusable view (a `FieldBox`'s inner
    /// `field`, or the control itself for a `SegmentedControl`) — the wrapper `FieldBox` isn't
    /// focusable, so the stop must be its text field (mirroring `AddWorkspaceOverlay`). `description`
    /// sits under the caption; `controlNote` (the range) sits under the input.
    private func addRow(
        key: String, caption: String, description: String?, control: NSView, focusStop: NSView,
        controlNote: String?, width: CGFloat?, to stack: NSStackView
    ) {
        let row = LayoutRow(
            caption: caption, description: description, control: control, controlNote: controlNote,
            controlWidth: width)
        wireControlKeyboard(control)
        rows.append(row)
        stops.append(focusStop)
        controlForKey[key] = control
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
        default:
            break
        }
    }

    // MARK: writes

    /// Commit a numeric field's value: write the canonical form, or remove the key when it's blank
    /// (blank = default). Invalid text never reaches here (the debounce is skipped while invalid).
    private func commitNumeric(_ knob: NumericKnob, box: FieldBox) {
        let text = box.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            writeOrRemove(knob.key, nil, row: knob.key)
            return
        }
        guard let value = LayoutFormat.parseNumber(text, in: knob.range) else { return }
        write(knob.key, LayoutFormat.number(value), row: knob.key)
    }

    private func write(_ key: String, _ value: String, row: String) {
        persist({ try ConfigWriter.apply(scalars: [key: value]) }, reportKey: row)
    }
    private func writeOrRemove(_ key: String, _ value: String?, row: String) {
        if let value {
            write(key, value, row: row)
        } else {
            persist({ try ConfigWriter.apply(removals: [key]) }, reportKey: row)
        }
    }
    private func resetAll() { persist({ try ConfigWriter.apply(removals: Set(self.scalarKeys)) }, reportKey: nil) }

    /// Run a write, reload, and refresh every row from the new config. On failure, report on the
    /// edited row and return — there's no staged state here (unlike keybinds) to roll back.
    private func persist(_ write: () throws -> Void, reportKey: String?) {
        do {
            try write()
        } catch {
            (reportKey.flatMap(rowFor) ?? rows.first)?.showMessage(
                "Couldn't write config: \(error.localizedDescription)")
            return
        }
        AppConfig.reload()
        refreshRows()
    }

    /// Sync every control to the reloaded config: a numeric field shows the value only when it's
    /// overridden (blank at default). Skip a field that's currently being edited so a live-apply
    /// write doesn't clobber the caret.
    private func refreshRows() {
        for (_, knobs) in Self.numericKnobs {
            for knob in knobs {
                guard let box = controlForKey[knob.key] as? FieldBox, box.field.currentEditor() == nil else { continue }
                box.setText(fieldText(for: knob))
            }
        }
        if let seg = controlForKey["reduce-motion"] as? SegmentedControl {
            seg.setSelection(reduceMotionIsOn() ? 0 : 1)
        }
        if let shellBox = controlForKey["shell"] as? FieldBox, shellBox.field.currentEditor() == nil {
            shellBox.setText(GeneralConfig.current.shell ?? "")
        }
        if let argsBox = controlForKey["shell-args"] as? FieldBox, argsBox.field.currentEditor() == nil {
            argsBox.setText(LayoutFormat.joinArgs(GeneralConfig.current.shellArgs))
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
    private func fieldText(for knob: NumericKnob) -> String {
        let current = knob.read(GeneralConfig.current)
        return current != knob.read(GeneralConfig.builtIn) ? LayoutFormat.number(current) : ""
    }

    private func rangeMessage(_ knob: NumericKnob) -> String {
        "Enter a number in \(rangeText(knob))."
    }

    private func rangeText(_ knob: NumericKnob) -> String {
        "\(LayoutFormat.number(knob.range.lowerBound))–\(LayoutFormat.number(knob.range.upperBound))"
    }

    /// Move focus between the vertical stops. Finds the current stop by which one is first responder
    /// (a stop may be a `FieldBox`'s field editor, so this is more robust than a passed-in view).
    private func moveFocus(_ delta: Int) {
        let window = stops.first?.window
        let anchor = stops.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        guard let next = KeyboardFocus.step(from: anchor, delta: delta, count: stops.count) else { return }
        let target = stops[next]
        target.window?.makeFirstResponder(target)
        let scrollTarget = rows.first { $0.subviews(recursively: target) } ?? target
        scrollTarget.scrollToVisible(scrollTarget.bounds.insetBy(dx: 0, dy: -12))
    }

    private func rowFor(_ key: String) -> LayoutRow? {
        guard let control = controlForKey[key] else { return nil }
        return rows.first { $0.subviews(recursively: control) }
    }
}

extension NSView {
    /// True if `view` is this view or nested anywhere beneath it — used to map a focused control
    /// back to its row for scroll-into-view and messaging.
    fileprivate func subviews(recursively view: NSView) -> Bool {
        if view === self { return true }
        return subviews.contains { $0.subviews(recursively: view) }
    }
}
