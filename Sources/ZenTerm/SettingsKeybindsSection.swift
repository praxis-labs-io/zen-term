import AppKit

/// The Keybinds settings section: remap the built-in actions. Each action's chord is a focusable
/// `KeybindChip` — Return/click begins capture (a hint bubble appears and the next chord is diverted
/// through the interceptor, so an already-bound chord isn't pre-empted), Backspace reverts to the
/// default. Rebinds are ≥1-modifier, block-on-conflict, written via `ConfigWriter` and reloaded via
/// `AppConfig` so they're live — no restart. A section reset returns everything to the defaults.
final class SettingsKeybindsSection: SettingsSection {
    var navTitle: String { "Shortcuts" }
    var onExitToNav: (() -> Void)?

    /// Editable actions grouped by category (float toggles are excluded — they're file-only).
    private static let groups: [(String, [KeyInterceptor.ReservedChord])] = [
        ("Panes", [.splitHorizontal, .splitVertical, .closePane, .toggleZoom]),
        ("Navigation", [.navLeft, .navDown, .navUp, .navRight]),
        ("Resize", [.resizeLeft, .resizeDown, .resizeUp, .resizeRight]),
        ("Tabs", [.newTab, .newWindow, .prevTab, .nextTab] + (1...9).map { .selectTab($0) }),
        ("Window", [.fillScreen]),
        ("Drawers", [.toggleBottomDrawer, .toggleRightDrawer]),
        (
            "Surfaces & Tools",
            [.toggleRepoPicker, .toggleCommandPalette, .openDiffViewer, .openSettings]
        ),
    ]

    private let capturer: KeybindCapturing?
    private var desired: [Chord: KeyInterceptor.ReservedChord] = [:]
    private var rows: [KeybindRow] = []
    /// Retained (not throwaway locals) so `reapplyTheme()` can recolor them in place.
    private var groupCaptions: [NSTextField] = []
    private let resetAllButton = AppButton(title: "Reset all to defaults", variant: .muted)
    private weak var detailScroll: NSScrollView?
    private var hintBubble: KeybindHintBubble?
    private var hintBackdrop: NSView?
    private weak var capturingRow: KeybindRow?
    private var captureCloseTimer: DispatchWorkItem?
    private let resetAllMessage = ResetFlashLabel()
    private var configObserver: NSObjectProtocol?
    /// A `.configDidChange` that arrived while a capture was armed, replayed once it ends.
    private var hasMissedConfigReload = false

    init(capturer: KeybindCapturing?) {
        self.capturer = capturer
        // Pick up a reload this card didn't make — ⌘⌥R after a hand-edit, or another window's
        // Settings write. Without it the chips and conflict messages keep showing the pre-reload
        // config, and ⌘⌥R is exactly what a user reaches for after editing the file to clear a
        // conflict this section just told them about.
        configObserver = NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] note in
            // The rows render from the keymap and their conflict messages from the diagnostics,
            // so anything else (a slider drag on another section, with this card open) is skippable.
            let change = ConfigChange.from(note)
            guard change.contains(.keymap) || change.contains(.diagnostics) else { return }
            self?.refreshFromConfig()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Re-read the live keymap into the rows IN PLACE — no rebuild, for the same reason
    /// `reapplyTheme` doesn't: `.configDidChange` is global, so rebuilding here would tear down a
    /// capture armed in a *different* window.
    ///
    /// A reload that lands mid-capture is *deferred*, not dropped. `desired` is the whole set
    /// `ConfigWriter` rewrites the keybind block from, so leaving it stale past the capture means
    /// the next successful write regenerates that block from pre-reload state — silently deleting
    /// keybind lines the reload had just brought in.
    private func refreshFromConfig() {
        guard !rows.isEmpty else { return }
        guard capturingRow == nil else {
            // Only a FOREIGN reload is worth deferring. This card's own write reloads too, and
            // `desired` already equals what it just wrote — flagging that would replay a refresh we
            // did a moment ago, and would blur the flag's meaning from "someone else changed the
            // config" into "a reload happened".
            hasMissedConfigReload = reservedEntries(of: GeneralConfig.current.keymap) != desired
            return
        }
        hasMissedConfigReload = false
        desired = reservedEntries(of: GeneralConfig.current.keymap)
        refreshRows()
    }

    /// Re-read `desired` from the live keymap when a reload was deferred, BEFORE an edit is layered
    /// on top of it. `desired` is the whole set `ConfigWriter` regenerates the keybind block from,
    /// so an edit applied to a pre-reload set writes that staleness to disk — deleting the very
    /// lines the reload brought in. `hideHint`'s replay is too late for that: `commitRebind` writes
    /// 0.7s before its close timer runs.
    private func rebaseIfReloadDeferred() {
        guard hasMissedConfigReload else { return }
        hasMissedConfigReload = false
        desired = reservedEntries(of: GeneralConfig.current.keymap)
    }

    func makeDetailView() -> NSView {
        desired = reservedEntries(of: GeneralConfig.current.keymap)
        rows = []
        groupCaptions = []

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
            let caption = SettingsDetail.groupCaption(category)
            rowsStack.addArrangedSubview(caption)
            groupCaptions.append(caption)
            if let previous { rowsStack.setCustomSpacing(18, after: previous) }  // gap between groups
            for action in actions {
                let row = KeybindRow(action: action, title: CommandCatalog.spec(for: action).title)
                // `weak row`: these closures live *on* the row's chip, so capturing it strongly would
                // be a retain cycle — every row would leak on each Settings open.
                row.chip.onActivate = { [weak self, weak row] in row.map { self?.beginCapture(for: $0) } }
                row.chip.onReset = { [weak self, weak row] in row.map { self?.reset($0) } }
                row.chip.onArrowUp = { [weak self, weak row] in row.map { self?.moveFocus(from: $0.chip, delta: -1) } }
                row.chip.onArrowDown = { [weak self, weak row] in row.map { self?.moveFocus(from: $0.chip, delta: 1) } }
                row.chip.onTab = { [weak self, weak row] in row.map { self?.moveTab(from: $0.chip, delta: 1) } }
                row.chip.onBacktab = { [weak self, weak row] in row.map { self?.moveTab(from: $0.chip, delta: -1) } }
                row.chip.onExitToNav = { [weak self] in self?.onExitToNav?() }
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
        resetAllButton.onTab = { [weak self] in
            guard let self else { return }
            self.moveTab(from: self.resetAllButton, delta: 1)
        }
        resetAllButton.onBacktab = { [weak self] in
            guard let self else { return }
            self.moveTab(from: self.resetAllButton, delta: -1)
        }
        resetAllButton.onTap = { [weak self] in self?.resetAll() }
        let resetRow = SettingsDetail.trailingRow(resetAllButton)
        rowsStack.addArrangedSubview(resetRow)
        resetRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        if let previous { rowsStack.setCustomSpacing(18, after: previous) }  // gap before Reset all

        let messageRow = SettingsDetail.trailingRow(resetAllMessage)
        rowsStack.addArrangedSubview(messageRow)
        messageRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        rowsStack.setCustomSpacing(6, after: resetRow)  // tuck the success line under the button

        let scroll = SettingsDetail.scroll(for: rowsStack)
        detailScroll = scroll
        refreshRows()
        return scroll
    }

    func detailStops() -> [NSView] { rows.map(\.chip) + [resetAllButton] }

    /// End an armed capture when the section is torn down (a nav switch) so the app-wide interceptor
    /// doesn't keep diverting keystrokes with the recording popover already gone.
    func sectionWillHide() {
        if let row = capturingRow { endCapture(row) }
    }

    /// Re-apply the section's theme-dependent colors IN PLACE — no rebuild, so this never routes
    /// through `makeDetailView()`/`selectSection` and never calls `sectionWillHide()`. Rebuilding
    /// here (as a naive recolor might) would tear down an in-progress capture — including one
    /// armed in a *different* window, since a theme swap is a global `.configDidChange` that every
    /// open Settings card observes. Recolors every group caption, every row (title/message/chip
    /// glyphs), and the persistent Reset-all button + its flash message.
    func reapplyTheme() {
        groupCaptions.forEach { $0.textColor = Theme.current.chrome.ink(alpha: 0.4) }
        rows.forEach { $0.reapplyTheme() }
        resetAllButton.reapplyTheme()
        resetAllMessage.reapplyTheme()
    }

    // MARK: edits

    /// Record a chord through the interceptor (so an already-bound chord isn't pre-empted), showing a
    /// hint bubble that previews the keys live. Capture stays armed — an invalid chord shows a warning
    /// and lets the user try again; only a valid chord commits (with a success line, then a delayed
    /// close). Esc cancels; Delete reverts to default.
    private func beginCapture(for row: KeybindRow) {
        // No interceptor means capture could never complete — bail before arming the row so it
        // doesn't stick on "Press keys…" with no way out. (Always wired in-app; a guard, not a path.)
        guard let capturer else {
            row.showMessage("Shortcut capture is unavailable.")
            return
        }
        captureCloseTimer?.cancel()
        capturingRow?.setCapturing(false)  // clear any prior capturing / just-committed chip's state
        row.setCapturing(true)
        row.showMessage(nil)
        showHint(for: row)  // calls hideHint, which nils capturingRow — so set it AFTER
        capturingRow = row
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
        // Route the physical-key decode through the shared decoder so the macOS keyCodes stay in
        // exactly one place (KeyboardFocus.key). Esc / Delete are commands, not recordable chords.
        switch KeyboardFocus.key(for: event) {
        case .escape: endCapture(row); refreshRows(); return  // Esc → cancel
        case .delete: endCapture(row); reset(row); return  // Backspace / Forward-Delete → default
        default: break
        }
        guard let chord = Chord(event: event) else { return }  // unmappable key — keep waiting
        hintBubble?.setPreview(chord.displayGlyph)
        hintBubble?.clearError()
        guard chord.command || chord.shift || chord.option || chord.control else {
            hintBubble?.showError("Add at least one modifier (⌘ ⇧ ⌥ ⌃).")
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
        rebaseIfReloadDeferred()  // layer this edit on the reloaded set, never a pre-reload one
        desired = desired.filter { $0.value != row.action }
        desired[chord] = row.action
        guard persist(reportingRow: row) else {  // write failed — persist showed the error; don't claim success
            endCapture(row)
            return
        }
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
    ///
    /// This is the one edit that picks its own chord rather than the user pressing it, so it's the
    /// one that can land on an occupied one. It takes the chord — Backspace always restores the
    /// default, and refusing deadlocks a swapped pair, where each action holds the other's default
    /// and neither row could ever be reverted. What it must not do is take it *silently*: whatever
    /// held the chord falls back to its own default, and its row says so.
    private func reset(_ row: KeybindRow) {
        rebaseIfReloadDeferred()  // layer the reset on the reloaded set, never a pre-reload one
        let displaced = defaultChordConflict(for: row.action)
        desired = desired.filter { $0.value != row.action }
        for (chord, action) in KeymapDefaults.map where action == row.action { desired[chord] = action }
        guard persist(reportingRow: row) else { return }  // persist reported the write error
        if let (chord, owner) = displaced { reportDisplacement(of: owner, losing: chord, to: row.action) }
        row.focusChip()  // keep focus on the row after the reload
    }

    /// Tell the displaced action's row it lost its chord, and where it landed — after `persist`, so
    /// its `refreshRows` doesn't clear the message before anyone reads it. A tool float has no row
    /// here; it doesn't need one, because a float that keeps its `key:` wins the chord back on
    /// reload and the losing action's own diagnostic explains that.
    private func reportDisplacement(
        of owner: KeyInterceptor.ReservedChord, losing chord: Chord, to winner: KeyInterceptor.ReservedChord
    ) {
        guard let ownerRow = rows.first(where: { $0.action == owner }) else { return }
        let winnerTitle = CommandCatalog.spec(for: winner).title
        let landed = displayedChord(for: owner)?.displayGlyph
        ownerRow.showMessage(
            landed.map { "\(chord.displayGlyph) went back to \(winnerTitle). This is \($0) now." }
                ?? "\(chord.displayGlyph) went back to \(winnerTitle).",
            kind: .notice)
    }

    /// The first of an action's default chords that some *other* action holds in the live keymap,
    /// with its holder. Read from the live keymap rather than `desired`, so a tool float's `key:`
    /// counts too — `desired` excludes float toggles, and a float is just as stealable.
    private func defaultChordConflict(
        for action: KeyInterceptor.ReservedChord
    ) -> (Chord, KeyInterceptor.ReservedChord)? {
        KeymapDefaults.map
            .filter { $0.value == action }
            .keys
            .sorted { $0.configToken < $1.configToken }  // deterministic: same chord named every time
            .lazy
            .compactMap { chord -> (Chord, KeyInterceptor.ReservedChord)? in
                guard let owner = GeneralConfig.current.keymap[chord], owner != action else { return nil }
                return (chord, owner)
            }
            .first
    }

    private func resetAll() {
        desired = reservedEntries(of: KeymapDefaults.map)
        guard persist(reportingRow: rows.last) else { return }  // report a write error near the button
        resetAllMessage.flash("Defaults restored.")
    }

    /// Write the override set, reload the live config, then refresh every row from the new keymap.
    /// Returns whether the write succeeded. A failure reports on `reportingRow` (the row the user was
    /// editing, kept in view by the focus scroll) so the message isn't stranded off-screen.
    @discardableResult
    private func persist(reportingRow: KeybindRow?) -> Bool {
        do {
            try ConfigWriter.apply(keybinds: desired)
        } catch {
            // Roll the failed edit out of the in-memory map, back to what's on disk — otherwise it
            // rides along on the next successful write, silently applying an edit the user was told
            // failed.
            desired = reservedEntries(of: GeneralConfig.current.keymap)
            refreshRows()
            (reportingRow ?? rows.first)?.showMessage(
                "Couldn't write config: \(error.localizedDescription)", kind: .failure)
            return false
        }
        AppConfig.reload()
        // This write landed, so any earlier write failure is resolved — `refreshRows` won't clear it
        // (a failure outlives a refresh by design), so retract it here where we know it's stale.
        rows.filter { $0.messageKind == .failure }.forEach { $0.showMessage(nil) }
        desired = reservedEntries(of: GeneralConfig.current.keymap)
        refreshRows()
        return true
    }

    /// Re-render every row from the live keymap. Owns each row's `.diagnostic` message: a chip is
    /// empty either because the action is genuinely unbound or because a config line took its last
    /// chord, and only the second deserves an explanation.
    ///
    /// A `.failure` message is left alone — it reports a write that didn't land, which a refresh
    /// doesn't resolve. Clearing it here would let an unrelated reload (a theme change in another
    /// window) silently retract "couldn't write config" while the edit is still not on disk.
    private func refreshRows() {
        let diagnostics = GeneralConfig.current.configDiagnostics
        for row in rows {
            row.render(currentShortcut: displayedChord(for: row.action)?.displayGlyph ?? "")
            guard row.messageKind != .failure else { continue }
            row.showMessage(diagnostics.first { $0.scope == .keybind(row.action) }?.message, kind: .diagnostic)
        }
    }

    // MARK: hint bubble

    /// Float a themed hint over the detail pane, just below the capturing chip. Added to the scroll
    /// view's superview (the detail container), so it tears down with the card — no orphaned bubble.
    private func showHint(for row: KeybindRow) {
        hideHint()
        guard let host = detailScroll?.superview else { return }
        // A transparent backdrop over the detail pane makes the popover modal: a click anywhere
        // outside it cancels (rather than falling through and starting capture on the chip beneath).
        let backdrop = BackdropView { [weak self] in self?.cancelCapture() }
        backdrop.frame = host.bounds
        backdrop.autoresizingMask = [.width, .height]
        host.addSubview(backdrop)
        hintBackdrop = backdrop
        let bubble = KeybindHintBubble()
        bubble.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(bubble)  // above the backdrop
        hintBubble = bubble
        positionBubble(for: row)
    }

    /// Dismiss an armed capture from a click outside the popover — cancel, no change (like Esc).
    private func cancelCapture() {
        guard let row = capturingRow else { hideHint(); return }
        endCapture(row)
        refreshRows()
    }

    /// (Re)place the bubble just below its chip — re-run whenever its height changes (a warning or
    /// success line replacing the instructions can grow it).
    private func positionBubble(for row: KeybindRow) {
        guard let bubble = hintBubble, let host = bubble.superview else { return }
        bubble.layoutSubtreeIfNeeded()
        let size = bubble.fittingSize
        let chipRect = row.chip.convert(row.chip.bounds, to: host)
        let x = max(8, min(chipRect.midX - size.width / 2, host.bounds.width - size.width - 8))
        // Place the popover just past the chip; if that would run off the pane (a chip low in the
        // scrolled list), use the far side, then clamp so it never draws off the bottom of the card.
        let primary = host.isFlipped ? (chipRect.maxY + 6) : (chipRect.minY - size.height - 6)
        let fallback = host.isFlipped ? (chipRect.minY - size.height - 6) : (chipRect.maxY + 6)
        let maxY = max(8, host.bounds.height - size.height - 8)
        var y = primary
        if y < 8 || y > maxY { y = fallback }
        y = max(8, min(y, maxY))
        bubble.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The single place a capture ends (Esc, Delete, a commit's close timer, a backdrop click), so
    /// it's where a reload deferred during that capture gets replayed.
    private func hideHint() {
        hintBubble?.removeFromSuperview()
        hintBubble = nil
        hintBackdrop?.removeFromSuperview()
        hintBackdrop = nil
        capturingRow = nil
        if hasMissedConfigReload { refreshFromConfig() }
    }

    /// The modifier-only glyph for the live preview while keys are still being held (⌘, ⌘⇧, …) —
    /// delegates to `Chord.modifierGlyph` so the ⌘⇧⌥⌃ order isn't re-encoded here.
    private static func modifierGlyph(_ flags: NSEvent.ModifierFlags) -> String {
        Chord.modifierGlyph(flags)
    }

    // MARK: helpers

    private func reservedEntries(
        of map: [Chord: KeyInterceptor.ReservedChord]
    ) -> [Chord: KeyInterceptor.ReservedChord] {
        map.filter { if case .toggleToolFloat = $0.value { return false } else { return true } }
    }

    /// The chord shown for an action — from `desired` (the in-progress edit set), not the live
    /// keymap, so an unsaved edit renders. Same pick as the palette's: see `Chord.displayed`.
    private func displayedChord(for action: KeyInterceptor.ReservedChord) -> Chord? {
        Chord.displayed(action, in: desired)
    }

    /// Move keyboard focus between the vertical stops (each row's chip, then "Reset all").
    private func moveFocus(from view: NSView, delta: Int) {
        let stops = rows.map(\.chip) + [resetAllButton]
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        // Scroll the whole row when the destination is a row's chip so the row's inline message
        // shows too; otherwise the stop itself.
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta) { [rows] target in
            rows.first { $0.chip === target } ?? target
        }
    }

    /// Tab traversal, which differs from the arrows at the ends: Tab wraps from the last stop back
    /// to the first, and Shift-Tab retreats one stop, exiting to the nav only from the first —
    /// mirroring how Left exits.
    private func moveTab(from view: NSView, delta: Int) {
        let stops = rows.map(\.chip) + [resetAllButton]
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        if delta < 0, anchor == 0 {
            onExitToNav?()
            return
        }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta, wrap: true) { [rows] target in
            rows.first { $0.chip === target } ?? target
        }
    }
}
