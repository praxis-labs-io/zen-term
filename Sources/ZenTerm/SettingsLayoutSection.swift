import AppKit

/// The Layout & Motion settings section: sliders/fields/segmented editors for the chrome layout
/// knobs, motion preference, and shell fields. Writes each edit via `ConfigWriter` scalars (a reset
/// removes the key → falls back to `builtIn`), reloads via `AppConfig`, and refreshes every row.
/// Live-appliable knobs update running windows through the `configDidChange` seam (Task 4); the
/// rest apply to new tabs, labeled as such.
final class SettingsLayoutSection: SettingsSection {
    var navTitle: String { "Layout & Motion" }
    var onExitToNav: (() -> Void)?
    var onClose: (() -> Void)?

    /// A numeric (CGFloat) knob: config key, caption, valid range, control style, and how to read
    /// its value from a resolved config. `builtIn = read(GeneralConfig.builtIn)`; overridden =
    /// `read(.current) != builtIn`. `note` labels new-tab-only knobs.
    private struct NumericKnob {
        enum Style { case slider(step: CGFloat), field }
        let key: String
        let caption: String
        let range: ClosedRange<CGFloat>
        let style: Style
        let note: String?
        let read: (GeneralConfig) -> CGFloat
    }

    private static let numericKnobs: [(String, [NumericKnob])] = [
        (
            "Layout",
            [
                NumericKnob(
                    key: "backdrop-alpha", caption: "Backdrop alpha", range: 0...1,
                    style: .slider(step: 0.02), note: nil, read: { $0.backdropAlpha }),
                NumericKnob(
                    key: "window-gutter", caption: "Window gutter", range: 0...64,
                    style: .field, note: "px", read: { $0.windowGutter }),
                NumericKnob(
                    key: "pane-gap", caption: "Pane gap", range: 0...64,
                    style: .field, note: "px", read: { $0.panelGap }),
                NumericKnob(
                    key: "bottom-drawer-fraction", caption: "Bottom drawer", range: 0.1...0.9,
                    style: .slider(step: 0.01), note: "new tabs", read: { $0.bottomDrawerFraction }),
                NumericKnob(
                    key: "right-drawer-fraction", caption: "Right drawer", range: 0.1...0.9,
                    style: .slider(step: 0.01), note: "new tabs", read: { $0.rightDrawerFraction }),
                NumericKnob(
                    key: "drawer-resize-step", caption: "Drawer resize step", range: 4...400,
                    style: .field, note: "px", read: { $0.drawerResizeStep }),
                NumericKnob(
                    key: "max-drawer-fraction", caption: "Max drawer", range: 0.3...0.95,
                    style: .slider(step: 0.01), note: nil, read: { $0.maxDrawerFraction }),
            ]
        )
    ]

    private let resetAllButton = AppButton(title: "Reset all to defaults", variant: .muted)
    private var rows: [LayoutRow] = []
    private var stops: [NSView] = []  // ordered vertical focus stops: each row's control + Reset-all
    private var controlForKey: [String: NSView] = [:]
    private var scalarKeys: [String] = []  // every key this section owns (for Reset-all)

    func makeDetailView() -> NSView {
        rows = []
        stops = []
        controlForKey = [:]
        scalarKeys = []

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 3
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        var previous: NSView?
        func addGroup(_ title: String, _ build: (NSStackView) -> Void) {
            let caption = NSTextField(labelWithString: title.uppercased())
            caption.font = .systemFont(ofSize: 10, weight: .semibold)
            caption.textColor = Theme.current.chrome.ink(alpha: 0.4)
            rowsStack.addArrangedSubview(caption)
            if let previous { rowsStack.setCustomSpacing(18, after: previous) }
            build(rowsStack)
            previous = rowsStack.arrangedSubviews.last
        }

        // Layout group (numeric knobs).
        for (groupTitle, knobs) in Self.numericKnobs {
            addGroup(groupTitle) { stack in
                for knob in knobs { self.addNumericRow(knob, to: stack) }
            }
        }
        // Motion group (reduce-motion segmented).
        addGroup("Motion") { stack in self.addReduceMotionRow(to: stack) }
        // Shell group (new-tab text fields).
        addGroup("Shell") { stack in self.addShellRows(to: stack) }

        resetAllButton.isKeyboardFocusable = true
        resetAllButton.onArrowUp = { [weak self] in
            guard let self else { return }
            self.moveFocus(from: self.resetAllButton, delta: -1)
        }
        resetAllButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        resetAllButton.onEsc = { [weak self] in self?.onClose?() }
        resetAllButton.onTap = { [weak self] in self?.resetAll() }
        rowsStack.addArrangedSubview(resetAllButton)
        if let previous { rowsStack.setCustomSpacing(18, after: previous) }
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
        let current = knob.read(GeneralConfig.current)
        let control: NSView
        switch knob.style {
        case .slider(let step):
            let slider = Slider(value: current, range: knob.range, step: step) { [weak self] value in
                self?.write(knob.key, LayoutFormat.number(value), row: knob.key)
            }
            control = slider
        case .field:
            let box = FieldBox(placeholder: LayoutFormat.number(knob.read(GeneralConfig.builtIn)))
            box.setText(LayoutFormat.number(current))
            box.onChange = { [weak self] in self?.validateAndWriteNumeric(knob, box: box) }
            control = box
        }
        let row = makeRow(key: knob.key, caption: knob.caption, control: control, note: knob.note)
        wireControlKeyboard(control, row: row)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addReduceMotionRow(to stack: NSStackView) {
        scalarKeys.append("reduce-motion")
        let index = LayoutFormat.reduceMotionIndex(GeneralConfig.current.reduceMotion)
        let segmented = SegmentedControl(options: ["System", "On", "Off"], selectedIndex: index) { [weak self] i in
            self?.write(
                "reduce-motion", LayoutFormat.reduceMotionToken(LayoutFormat.reduceMotion(fromIndex: i)),
                row: "reduce-motion")
        }
        let row = makeRow(key: "reduce-motion", caption: "Reduce motion", control: segmented, note: nil)
        wireControlKeyboard(segmented, row: row)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addShellRows(to stack: NSStackView) {
        scalarKeys.append(contentsOf: ["shell", "shell-args"])
        let shellBox = FieldBox(placeholder: "login shell")
        shellBox.setText(GeneralConfig.current.shell ?? "")
        shellBox.onChange = { [weak self] in
            let text = shellBox.text.trimmingCharacters(in: .whitespaces)
            self?.writeOrRemove("shell", text.isEmpty ? nil : text, row: "shell")
        }
        let shellRow = makeRow(key: "shell", caption: "Shell", control: shellBox, note: "new tabs")
        wireControlKeyboard(shellBox, row: shellRow)
        stack.addArrangedSubview(shellRow)
        shellRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let argsBox = FieldBox(placeholder: "—")
        argsBox.setText(LayoutFormat.joinArgs(GeneralConfig.current.shellArgs))
        argsBox.onChange = { [weak self] in
            let joined = LayoutFormat.joinArgs(LayoutFormat.splitArgs(argsBox.text))
            self?.writeOrRemove("shell-args", joined.isEmpty ? nil : joined, row: "shell-args")
        }
        let argsRow = makeRow(key: "shell-args", caption: "Shell args", control: argsBox, note: "new tabs")
        wireControlKeyboard(argsBox, row: argsRow)
        stack.addArrangedSubview(argsRow)
        argsRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeRow(key: String, caption: String, control: NSView, note: String?) -> LayoutRow {
        let row = LayoutRow(caption: caption, control: control, note: note)
        row.onReset = { [weak self] in self?.reset(key: key, row: row) }
        row.onArrowUp = { [weak self, weak control] in control.map { self?.moveFocus(from: $0, delta: -1) } }
        row.onArrowDown = { [weak self, weak control] in control.map { self?.moveFocus(from: $0, delta: 1) } }
        row.onEsc = { [weak self] in self?.onClose?() }
        row.onFocusControl = { [weak control] in control?.window?.makeFirstResponder(control) }
        rows.append(row)
        stops.append(control)
        controlForKey[key] = control
        return row
    }

    /// Wire a control's Up/Down (move rows), Tab (→ this row's reset), Left-at-boundary/⇧Tab
    /// (→ nav or prev), and Esc through the row/section. Handles the three control types.
    private func wireControlKeyboard(_ control: NSView, row: LayoutRow) {
        let toReset: () -> Void = { [weak row] in
            guard let row else { return }
            row.focusReset()
        }
        switch control {
        case let slider as Slider:
            slider.onArrowUp = { [weak self] in self?.moveFocus(from: slider, delta: -1) }
            slider.onArrowDown = { [weak self] in self?.moveFocus(from: slider, delta: 1) }
            slider.onTab = toReset
            slider.onBacktab = { [weak self] in self?.onExitToNav?() }
            slider.onEsc = { [weak self] in self?.onClose?() }
        case let box as FieldBox:
            box.onArrowUp = { [weak self] in self?.moveFocus(from: box, delta: -1) }
            box.onArrowDown = { [weak self] in self?.moveFocus(from: box, delta: 1) }
            box.onArrowLeft = { [weak self] in self?.onExitToNav?() }  // Left at cursor-start → nav
            box.onTab = toReset
            box.onBacktab = { [weak self] in self?.onExitToNav?() }
            box.onEsc = { [weak self] in self?.onClose?() }
        case let seg as SegmentedControl:
            seg.onArrowUp = { [weak self] in self?.moveFocus(from: seg, delta: -1) }
            seg.onArrowDown = { [weak self] in self?.moveFocus(from: seg, delta: 1) }
            seg.onTab = toReset
            seg.onBacktab = { [weak self] in self?.onExitToNav?() }
        default:
            break
        }
    }

    // MARK: writes

    private func validateAndWriteNumeric(_ knob: NumericKnob, box: FieldBox) {
        guard let value = LayoutFormat.parseNumber(box.text, in: knob.range) else {
            rowFor(knob.key)?.showMessage(
                "Enter a number in \(LayoutFormat.number(knob.range.lowerBound))–\(LayoutFormat.number(knob.range.upperBound))."
            )
            return
        }
        rowFor(knob.key)?.showMessage(nil)
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
    private func reset(key: String, row: LayoutRow) {
        persist({ try ConfigWriter.apply(removals: [key]) }, reportKey: key)
    }
    private func resetAll() { persist({ try ConfigWriter.apply(removals: Set(self.scalarKeys)) }, reportKey: nil) }

    /// Run a write, reload, and refresh every row from the new config. On failure, report on the
    /// edited row and rebuild the detail view so controls snap back to disk state.
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

    private func refreshRows() {
        for (_, knobs) in Self.numericKnobs {
            for knob in knobs {
                let overridden = knob.read(GeneralConfig.current) != knob.read(GeneralConfig.builtIn)
                rowFor(knob.key)?.render(isOverridden: overridden)
                if let slider = controlForKey[knob.key] as? Slider { slider.setValue(knob.read(GeneralConfig.current)) }
                if let box = controlForKey[knob.key] as? FieldBox {
                    box.setText(LayoutFormat.number(knob.read(GeneralConfig.current)))
                }
            }
        }
        let motion = GeneralConfig.current.reduceMotion
        rowFor("reduce-motion")?.render(isOverridden: motion != GeneralConfig.builtIn.reduceMotion)
        rowFor("shell")?.render(isOverridden: GeneralConfig.current.shell != GeneralConfig.builtIn.shell)
        rowFor("shell-args")?.render(isOverridden: GeneralConfig.current.shellArgs != GeneralConfig.builtIn.shellArgs)
    }

    // MARK: focus

    private func moveFocus(from view: NSView, delta: Int) {
        guard let index = stops.firstIndex(where: { $0 === view }) else { return }
        guard let next = KeyboardFocus.step(from: index, delta: delta, count: stops.count) else { return }
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

private extension NSView {
    /// True if `view` is this view or nested anywhere beneath it — used to map a focused control
    /// back to its row for scroll-into-view and messaging.
    func subviews(recursively view: NSView) -> Bool {
        if view === self { return true }
        return subviews.contains { $0.subviews(recursively: view) }
    }
}
