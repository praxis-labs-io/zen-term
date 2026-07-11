import AppKit

/// The Keybinds settings section: remap the built-in actions. Each action's chord is a focusable
/// `KeybindChip` — Return/click begins capture (a hint bubble appears and the next chord is diverted
/// through the interceptor, so an already-bound chord isn't pre-empted), Backspace reverts to the
/// default. Rebinds are ≥1-modifier, block-on-conflict, written via `ConfigWriter` and reloaded via
/// `AppConfig` so they're live — no restart. A section reset returns everything to the defaults.
final class SettingsKeybindsSection: SettingsSection {
    var navTitle: String { "Keybinds" }
    var onExitToNav: (() -> Void)?
    var onClose: (() -> Void)?

    /// Editable actions grouped by category (float toggles are excluded — they're file-only).
    private static let groups: [(String, [KeyInterceptor.ReservedChord])] = [
        ("Panes", [.splitHorizontal, .splitVertical, .closePane]),
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
    private weak var detailScroll: NSScrollView?
    private var hintBubble: KeybindHintBubble?
    private var captureCloseTimer: DispatchWorkItem?

    init(capturer: KeybindCapturing?) { self.capturer = capturer }

    func makeDetailView() -> NSView {
        desired = reservedEntries(of: GeneralConfig.current.keymap)
        rows = []

        // The rows list, built like the command palette: a flipped document view (top-down scroll
        // coords, so it opens at the top — not mid-scroll) holding a vertical stack, in a slim-overlay
        // scroll view. No redundant title here; the left nav already names the section.
        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 3
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        var previous: NSView?
        for (category, actions) in Self.groups {
            let caption = NSTextField(labelWithString: category.uppercased())
            caption.font = .systemFont(ofSize: 10, weight: .semibold)
            caption.textColor = Theme.current.chrome.ink(alpha: 0.4)
            rowsStack.addArrangedSubview(caption)
            if let previous { rowsStack.setCustomSpacing(18, after: previous) }  // gap between groups
            for action in actions {
                let row = KeybindRow(action: action, title: CommandCatalog.spec(for: action).title)
                // `weak row`: these closures live *on* the row's chip, so capturing it strongly would
                // be a retain cycle — every row would leak on each Settings open.
                row.chip.onActivate = { [weak self, weak row] in row.map { self?.beginCapture(for: $0) } }
                row.chip.onReset = { [weak self, weak row] in row.map { self?.reset($0) } }
                row.chip.onArrowUp = { [weak self, weak row] in row.map { self?.moveFocus(from: $0.chip, delta: -1) } }
                row.chip.onArrowDown = { [weak self, weak row] in row.map { self?.moveFocus(from: $0.chip, delta: 1) } }
                row.chip.onExitToNav = { [weak self] in self?.onExitToNav?() }
                row.chip.onEsc = { [weak self] in self?.onClose?() }
                rows.append(row)
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                previous = row
            }
        }

        // "Reset all" is the final vertical focus stop after the rows (reachable by arrowing down).
        resetAllButton.isKeyboardFocusable = true
        resetAllButton.onArrowUp = { [weak self] in
            guard let self else { return }
            self.moveFocus(from: self.resetAllButton, delta: -1)
        }
        resetAllButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        resetAllButton.onEsc = { [weak self] in self?.onClose?() }
        resetAllButton.onTap = { [weak self] in self?.resetAll() }
        rowsStack.addArrangedSubview(resetAllButton)
        if let previous { rowsStack.setCustomSpacing(18, after: previous) }  // gap before Reset all

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
        detailScroll = scroll

        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            // Inset the rows within the flipped document — padding on all four sides.
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 18),
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -18),
        ])
        refreshRows()
        return scroll
    }

    func detailStops() -> [NSView] { rows.map(\.chip) + [resetAllButton] }

    // MARK: edits

    /// Record a chord through the interceptor (so an already-bound chord isn't pre-empted), showing a
    /// hint bubble that previews the keys live. Capture stays armed — an invalid chord shows a warning
    /// and lets the user try again; only a valid chord commits (with a success line, then a delayed
    /// close). Esc cancels; Delete reverts to default.
    private func beginCapture(for row: KeybindRow) {
        // No interceptor means capture could never complete — bail before arming the row so it
        // doesn't stick on "Press keys…" with no way out. (Always wired in-app; a guard, not a path.)
        guard let capturer else {
            row.showMessage("Keybind capture is unavailable.")
            return
        }
        captureCloseTimer?.cancel()
        row.setCapturing(true)
        row.showMessage(nil)
        showHint(for: row)
        capturer.beginCapture { [weak self, weak row] event in
            guard let self, let row else { return }
            self.handleCaptureEvent(event, for: row)
        }
    }

    private func handleCaptureEvent(_ event: NSEvent, for row: KeybindRow) {
        if event.type == .flagsChanged {  // live modifier preview (⌘, ⌘⇧, …) before a key lands
            hintBubble?.setPreview(Self.modifierGlyph(event.modifierFlags))
            return
        }
        // keyDown. Esc / backspace / forward-delete are commands (the popover promises them), not
        // recordable chords.
        if event.keyCode == 53 { endCapture(row); refreshRows(); return }  // Esc → cancel
        if event.keyCode == 51 || event.keyCode == 117 { endCapture(row); reset(row); return }  // Delete → default
        guard let chord = Chord(event: event) else { return }  // unmappable key — keep waiting
        hintBubble?.setPreview(chord.displayGlyph)
        hintBubble?.clearError()
        guard chord.command || chord.shift || chord.option || chord.control else {
            hintBubble?.showError("Shortcuts need at least one modifier — ⌘ ⇧ ⌥ ⌃.")
            positionBubble(for: row)
            return  // stay armed
        }
        if let owner = GeneralConfig.current.keymap[chord], owner != row.action {
            hintBubble?.showError(
                "\(chord.displayGlyph) is already bound to \(CommandCatalog.spec(for: owner).title).")
            positionBubble(for: row)
            return  // stay armed
        }
        commitRebind(row, to: chord)  // valid — apply, show success, close after a beat
    }

    /// Apply a validated rebind, flash a success line, and close the popover after a short delay.
    private func commitRebind(_ row: KeybindRow, to chord: Chord) {
        capturer?.endCapture()
        desired = desired.filter { $0.value != row.action }
        desired[chord] = row.action
        persist(reportingRow: row)
        hintBubble?.setPreview(chord.displayGlyph)
        hintBubble?.showSuccess("Shortcut saved.")
        positionBubble(for: row)
        let close = DispatchWorkItem { [weak self, weak row] in
            self?.hideHint()
            row?.setCapturing(false)
        }
        captureCloseTimer = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: close)
    }

    /// End an armed capture immediately (Esc / Delete) — the caller then restores or resets the row.
    private func endCapture(_ row: KeybindRow) {
        captureCloseTimer?.cancel()
        capturer?.endCapture()
        hideHint()
        row.setCapturing(false)
    }

    /// Backspace on a focused chip: revert the action to its built-in default chord(s).
    private func reset(_ row: KeybindRow) {
        desired = desired.filter { $0.value != row.action }
        for (chord, action) in KeymapDefaults.map where action == row.action { desired[chord] = action }
        row.showMessage(nil)
        persist(reportingRow: row)
        row.focusChip()  // keep focus on the row after the reload
    }

    private func resetAll() {
        desired = reservedEntries(of: KeymapDefaults.map)
        rows.forEach { $0.showMessage(nil) }
        persist(reportingRow: rows.last)  // Reset-all lives at the bottom — report near it, not the top
    }

    /// Write the override set, reload the live config, then refresh every row from the new keymap. A
    /// write failure reports on `reportingRow` (the row the user was editing, kept in view by the
    /// focus scroll) so the message isn't stranded off-screen at the top of a long list.
    private func persist(reportingRow: KeybindRow?) {
        do {
            try ConfigWriter.apply(keybinds: desired)
        } catch {
            (reportingRow ?? rows.first)?.showMessage("Couldn't write config: \(error.localizedDescription)")
            // Roll the failed edit out of the in-memory map, back to what's on disk — otherwise it
            // rides along on the next successful write, silently applying an edit the user was told
            // failed. (`refreshRows` restores the chips; it leaves the error message set.)
            desired = reservedEntries(of: GeneralConfig.current.keymap)
            refreshRows()
            return
        }
        AppConfig.reload()
        desired = reservedEntries(of: GeneralConfig.current.keymap)
        refreshRows()
    }

    private func refreshRows() {
        for row in rows {
            row.render(currentShortcut: displayedChord(for: row.action)?.displayGlyph ?? "")
        }
    }

    // MARK: hint bubble

    /// Float a themed hint over the detail pane, just below the capturing chip. Added to the scroll
    /// view's superview (the detail container), so it tears down with the card — no orphaned bubble.
    private func showHint(for row: KeybindRow) {
        hideHint()
        guard let host = detailScroll?.superview else { return }
        let bubble = KeybindHintBubble()
        bubble.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(bubble)
        hintBubble = bubble
        positionBubble(for: row)
    }

    /// (Re)place the bubble just below its chip — re-run whenever its height changes (a warning or
    /// success line replacing the instructions can grow it).
    private func positionBubble(for row: KeybindRow) {
        guard let bubble = hintBubble, let host = bubble.superview else { return }
        bubble.layoutSubtreeIfNeeded()
        let size = bubble.fittingSize
        let chipRect = row.chip.convert(row.chip.bounds, to: host)
        let x = max(8, min(chipRect.midX - size.width / 2, host.bounds.width - size.width - 8))
        let y = host.isFlipped ? (chipRect.maxY + 6) : (chipRect.minY - size.height - 6)
        bubble.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func hideHint() {
        hintBubble?.removeFromSuperview()
        hintBubble = nil
    }

    /// The modifier-only glyph for the live preview while keys are still being held (⌘, ⌘⇧, …).
    private static func modifierGlyph(_ flags: NSEvent.ModifierFlags) -> String {
        var glyph = ""
        if flags.contains(.command) { glyph += "⌘" }
        if flags.contains(.shift) { glyph += "⇧" }
        if flags.contains(.option) { glyph += "⌥" }
        if flags.contains(.control) { glyph += "⌃" }
        return glyph
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

    /// Move keyboard focus between the vertical stops (each row's chip, then "Reset all").
    private func moveFocus(from view: NSView, delta: Int) {
        let stops = rows.map(\.chip) + [resetAllButton]
        guard let index = stops.firstIndex(where: { $0 === view }) else { return }
        guard let next = KeyboardFocus.step(from: index, delta: delta, count: stops.count) else { return }
        let target = stops[next]
        target.window?.makeFirstResponder(target)
        // AppKit doesn't scroll to a newly-focused responder — keep it in view. Scroll the whole row
        // when the stop is a row's chip so the row's inline message shows too; else the stop itself.
        let scrollTarget: NSView = rows.first { $0.chip === target } ?? target
        scrollTarget.scrollToVisible(scrollTarget.bounds.insetBy(dx: 0, dy: -12))
    }
}
