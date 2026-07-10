import AppKit

/// The Keybinds settings section: remap the built-in actions. Reads the live keymap, captures a
/// new chord per row (press-to-record, ≥1 modifier, block-on-conflict), writes the override set
/// via `ConfigWriter`, and reloads via `AppConfig` so the rebind is live — no restart. Per-row
/// and section reset return bindings to their built-in defaults.
final class SettingsKeybindsSection: SettingsSection {
    var navTitle: String { "Keybinds" }
    var onExitToNav: (() -> Void)?

    /// Editable actions grouped by category (float toggles are excluded — they're file-only).
    private static let groups: [(String, [KeyInterceptor.ReservedChord])] = [
        ("Splits", [.splitHorizontal, .splitVertical]),
        ("Navigation", [.navLeft, .navDown, .navUp, .navRight]),
        ("Resize", [.resizeLeft, .resizeDown, .resizeUp, .resizeRight]),
        ("Tabs", [.newTab, .newWindow, .prevTab, .nextTab] + (1...9).map { .selectTab($0) }),
        ("Drawers", [.toggleBottomDrawer, .toggleRightDrawer, .toggleZoom]),
        ("Surfaces & Tools", [.toggleLazygit, .toggleRepoPicker, .toggleCommandPalette, .addWorkspace, .openSettings]),
    ]

    private let capturer: KeybindCapturing?
    private var desired: [Chord: KeyInterceptor.ReservedChord] = [:]
    private var rows: [KeybindRow] = []
    private let resetAllButton = AppButton(title: "Reset all to defaults", variant: .muted)

    init(capturer: KeybindCapturing?) { self.capturer = capturer }

    func makeDetailView() -> NSView {
        desired = reservedEntries(of: GeneralConfig.current.keymap)
        rows = []

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Keybinds")
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        stack.addArrangedSubview(header)

        for (category, actions) in Self.groups {
            let caption = NSTextField(labelWithString: category.uppercased())
            caption.font = .systemFont(ofSize: 10, weight: .semibold)
            caption.textColor = Theme.current.chrome.ink(alpha: 0.4)
            stack.addArrangedSubview(caption)
            for action in actions {
                let row = KeybindRow(action: action, title: CommandCatalog.spec(for: action).title)
                row.onArrowUp = { [weak self] in self?.moveFocus(from: row.recordButton, delta: -1) }
                row.onArrowDown = { [weak self] in self?.moveFocus(from: row.recordButton, delta: 1) }
                row.onArrowLeft = { [weak self] in self?.onExitToNav?() }
                row.onRecordTapped = { [weak self] in self?.beginCapture(for: row) }
                row.onReset = { [weak self] in self?.reset(row) }
                rows.append(row)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        // "Reset all" is the final vertical focus stop after the rows (reachable by arrowing down).
        resetAllButton.isKeyboardFocusable = true
        resetAllButton.onArrowUp = { [weak self] in
            guard let self else { return }
            self.moveFocus(from: self.resetAllButton, delta: -1)
        }
        resetAllButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        resetAllButton.onTap = { [weak self] in self?.resetAll() }
        stack.addArrangedSubview(resetAllButton)

        // The scroll view fills the detail area edge-to-edge; all the padding lives inside as content
        // insets, so the list scrolls right up to the card edges with breathing room around the rows.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay  // thin, auto-hiding — not the wide legacy scroller
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        refreshRows()
        return scroll
    }

    func detailStops() -> [NSView] { rows.map(\.recordButton) + [resetAllButton] }

    // MARK: edits

    /// Record the next chord through the interceptor (so an already-bound chord isn't pre-empted),
    /// then rebind. Esc cancels; capture is one-shot (the handler ends it on the first event).
    private func beginCapture(for row: KeybindRow) {
        row.setCapturing(true)
        row.showMessage(nil)
        capturer?.beginCapture { [weak self, weak row] event in
            guard let self, let row else { return }
            self.capturer?.endCapture()
            row.setCapturing(false)
            if event.keyCode == 53 { return }  // Esc cancels — no change
            guard let chord = Chord(event: event) else { return }
            self.rebind(row, to: chord)
        }
    }

    private func rebind(_ row: KeybindRow, to chord: Chord) {
        guard chord.command || chord.shift || chord.option || chord.control else {
            row.showMessage("Needs at least one modifier."); return
        }
        if let owner = GeneralConfig.current.keymap[chord], owner != row.action {
            row.showMessage("\(chord.displayGlyph) is already bound to \(CommandCatalog.spec(for: owner).title).")
            return
        }
        row.showMessage(nil)
        desired = desired.filter { $0.value != row.action }  // drop this action's old chord(s)
        desired[chord] = row.action  // the chord is free — a conflict would have been blocked above
        persist()
    }

    private func reset(_ row: KeybindRow) {
        desired = desired.filter { $0.value != row.action }
        for (chord, action) in KeymapDefaults.map where action == row.action { desired[chord] = action }
        row.showMessage(nil)
        persist()
    }

    private func resetAll() {
        desired = reservedEntries(of: KeymapDefaults.map)
        rows.forEach { $0.showMessage(nil) }
        persist()
    }

    /// Write the override set, reload the live config, then refresh every row from the new keymap.
    private func persist() {
        do {
            try ConfigWriter.apply(keybinds: desired)
        } catch {
            rows.first?.showMessage("Couldn't write config: \(error.localizedDescription)")
            return
        }
        AppConfig.reload()
        desired = reservedEntries(of: GeneralConfig.current.keymap)
        refreshRows()
    }

    private func refreshRows() {
        for row in rows {
            let shortcut = displayedChord(for: row.action)?.displayGlyph ?? ""
            row.render(currentShortcut: shortcut, isOverridden: isOverridden(row.action))
        }
    }

    // MARK: helpers

    private func reservedEntries(
        of map: [Chord: KeyInterceptor.ReservedChord]
    ) -> [Chord: KeyInterceptor.ReservedChord] {
        map.filter { if case .toggleToolFloat = $0.value { return false } else { return true } }
    }

    /// The chord shown for an action — the deterministic first of its `desired` chords by token.
    private func displayedChord(for action: KeyInterceptor.ReservedChord) -> Chord? {
        desired.filter { $0.value == action }.map(\.key).sorted { $0.configToken < $1.configToken }.first
    }

    /// True when the action's current chords differ from its built-in defaults.
    private func isOverridden(_ action: KeyInterceptor.ReservedChord) -> Bool {
        let current = Set(desired.filter { $0.value == action }.map(\.key))
        let defaults = Set(KeymapDefaults.map.filter { $0.value == action }.map(\.key))
        return current != defaults
    }

    /// Move keyboard focus between the vertical stops (each row's record button, then "Reset all").
    private func moveFocus(from view: NSView, delta: Int) {
        let stops = rows.map(\.recordButton) + [resetAllButton]
        guard let index = stops.firstIndex(where: { $0 === view }) else { return }
        guard let next = KeyboardFocus.step(from: index, delta: delta, count: stops.count) else { return }
        let target = stops[next]
        target.window?.makeFirstResponder(target)
        // AppKit doesn't scroll to a newly-focused responder — keep it in view. Scroll the whole row
        // when the stop is a row's record button so the row's inline message shows too; else the stop
        // itself. A little padding keeps it off the clip edge.
        let scrollTarget: NSView = rows.first { $0.recordButton === target } ?? target
        scrollTarget.scrollToVisible(scrollTarget.bounds.insetBy(dx: 0, dy: -12))
    }
}
