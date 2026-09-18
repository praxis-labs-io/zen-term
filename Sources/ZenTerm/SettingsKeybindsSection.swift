import AppKit

final class SettingsKeybindsSection: SettingsSection {
    var navTitle: String { "Shortcuts" }
    var onExitToNav: (() -> Void)?

    static let groups: [(String, [KeyInterceptor.ReservedChord])] = [
        ("Panes", [.splitHorizontal, .splitVertical, .closePane, .toggleZoom]),
        (
            "Scrollback",
            [
                .toggleScrollMode, .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown,
                .jumpToPreviousPrompt, .jumpToNextPrompt, .scrollToSelection,
            ]
        ),
        ("Find", [.toggleSearch, .searchSelection, .findNext, .findPrevious]),
        (
            "Screen",
            [
                .clearScreen, .pasteSelection, .writeScreenFile, .copyScreenFilePath,
                .openScreenFile,
            ]
        ),
        ("Navigation", [.navLeft, .navDown, .navUp, .navRight, .prevPane, .nextPane]),
        ("Resize", [.resizeLeft, .resizeDown, .resizeUp, .resizeRight]),
        (
            "Tabs",
            [
                .newTab, .newWindow, .prevTab, .nextTab, .moveTabLeft, .moveTabRight, .renameTab,
                .closeTab,
            ]
                + (1...9).map { .selectTab($0) }
        ),
        ("Window", [.fillScreen, .closeWindow, .dismissToast, .dismissAllToasts]),
        ("Drawers", [.toggleBottomDrawer, .toggleRightDrawer]),
        (
            "Surfaces & Tools",
            [
                .toggleToolFloat(ToolFloat.scratch.id), .toggleRepoPicker, .createWorktree,
                .removeWorktree, .toggleCommandPalette, .newTool, .openSettings,
            ]
        ),
    ]

    private let capturer: KeybindCapturing?
    private var desired = KeymapOverrides()
    private var rows: [KeybindRow] = []
    private var groupCaptions: [NSTextField] = []
    private let resetAllButton = AppButton(title: "Reset all to defaults", variant: .muted)
    private weak var detailScroll: NSScrollView?
    private var hintBubble: KeybindHintBubble?
    private var hintBackdrop: NSView?
    private weak var capturingRow: KeybindRow?
    private var captureCloseTimer: DispatchWorkItem?
    private let resetAllMessage = ResetFlashLabel()
    private var configObserver: NSObjectProtocol?
    private var hasMissedConfigReload = false

    init(capturer: KeybindCapturing?) {
        self.capturer = capturer
        configObserver = NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] note in
            let change = ConfigChange.from(note)
            guard change.contains(.keymap) || change.contains(.diagnostics) else { return }
            MainActor.assumeIsolated { self?.refreshFromConfig() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Updates in place, since a rebuild would tear down a capture armed in another window.
    private func refreshFromConfig() {
        guard !rows.isEmpty else { return }
        guard capturingRow == nil else {
            hasMissedConfigReload = KeymapOverrides(config: .current) != desired
            return
        }
        hasMissedConfigReload = false
        desired = KeymapOverrides(config: .current)
        refreshRows()
    }

    /// Runs before an edit: `commitRebind` writes 0.7s before `hideHint` replays the deferred reload.
    private func rebaseIfReloadDeferred() {
        guard hasMissedConfigReload else { return }
        hasMissedConfigReload = false
        desired = KeymapOverrides(config: .current)
    }

    func makeDetailView() -> NSView {
        desired = KeymapOverrides(config: .current)
        rows = []
        groupCaptions = []

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
            if let previous { rowsStack.setCustomSpacing(18, after: previous) }
            for action in actions {
                let row = KeybindRow(action: action, title: CommandCatalog.spec(for: action).title)
                row.chip.onActivate = { [weak self, weak row] in row.map { self?.beginCapture(for: $0) } }
                row.chip.onRemove = { [weak self, weak row] in row.map { self?.remove($0) } }
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
        if let previous { rowsStack.setCustomSpacing(18, after: previous) }

        let messageRow = SettingsDetail.trailingRow(resetAllMessage)
        rowsStack.addArrangedSubview(messageRow)
        messageRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        rowsStack.setCustomSpacing(6, after: resetRow)

        let scroll = SettingsDetail.scroll(for: rowsStack)
        detailScroll = scroll
        refreshRows()
        return scroll
    }

    func detailStops() -> [NSView] { rows.map(\.chip) + [resetAllButton] }

    func sectionWillHide() {
        if let row = capturingRow { endCapture(row) }
    }

    func reapplyTheme() {
        groupCaptions.forEach { $0.textColor = Theme.current.chrome.ink(.muted) }
        rows.forEach { $0.reapplyTheme() }
        resetAllButton.reapplyTheme()
        resetAllMessage.reapplyTheme()
    }

    private func beginCapture(for row: KeybindRow) {
        guard let capturer else {
            row.showMessage("Shortcut capture is unavailable.")
            return
        }
        captureCloseTimer?.cancel()
        capturingRow?.setCapturing(false)
        row.setCapturing(true)
        row.showMessage(nil)
        showHint(for: row)
        capturingRow = row
        capturer.beginCapture { [weak self, weak row] event in
            guard let self, let row else { return }
            self.handleCaptureEvent(event, for: row)
        }
    }

    private func handleCaptureEvent(_ event: NSEvent, for row: KeybindRow) {
        if event.type == .flagsChanged {
            hintBubble?.setPreview(Self.modifierGlyph(event.modifierFlags))
            return
        }
        let isRecordable = event.keyCode == 51 && !KeyboardFocus.isUnmodified(event)
        switch KeyboardFocus.key(for: event) {
        case .escape: endCapture(row); refreshRows(); return
        case .delete where !isRecordable:
            endCapture(row)
            remove(row)
            return
        default: break
        }
        guard let chord = Chord(event: event) else { return }
        hintBubble?.setPreview(chord.displayGlyph)
        hintBubble?.clearError()
        guard chord.command || chord.shift || chord.option || chord.control else {
            refuse("Add at least one modifier (⌘ ⇧ ⌥ ⌃).", for: row)
            return
        }
        if let menuItem = MenuShortcuts.owner(of: chord) {
            refuse("\(chord.displayGlyph) is the \(menuItem) menu shortcut.", for: row)
            return
        }
        if let owner = GeneralConfig.current.keymap[chord], owner != row.action {
            refuse(
                "\(chord.displayGlyph) is already bound to \(CommandCatalog.spec(for: owner).title).",
                for: row)
            return
        }
        commitRebind(row, to: chord)
    }

    private func refuse(_ reason: String, for row: KeybindRow) {
        hintBubble?.setPreview("")
        hintBubble?.showError(reason)
        positionBubble(for: row)
    }

    private func isAtDefault(_ action: KeyInterceptor.ReservedChord) -> Bool {
        !desired.unbound.contains(action)
            && desired.chords(of: action) == Set(KeymapDefaults.chords(of: action))
    }

    private func commitRebind(_ row: KeybindRow, to chord: Chord) {
        capturer?.endCapture()
        rebaseIfReloadDeferred()
        desired.bind(row.action, to: [chord])
        guard persist(reportingRow: row) else {
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

    private func endCapture(_ row: KeybindRow) {
        captureCloseTimer?.cancel()
        capturer?.endCapture()
        hideHint()
        row.setCapturing(false)
    }

    /// Takes an occupied default chord, since refusing would deadlock a swapped pair.
    private func reset(_ row: KeybindRow) {
        rebaseIfReloadDeferred()
        let displaced = defaultChordConflict(for: row.action)
        desired.bind(row.action, to: KeymapDefaults.chords(of: row.action))
        guard persist(reportingRow: row) else { return }
        if let (chord, owner) = displaced { reportDisplacement(of: owner, losing: chord, to: row.action) }
        row.focusChip()
    }

    private func remove(_ row: KeybindRow) {
        rebaseIfReloadDeferred()
        desired.unbind(row.action)
        guard persist(reportingRow: row) else { return }
        row.focusChip()
    }

    /// Runs after `persist`, whose row refresh would clear the message.
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

    private func defaultChordConflict(
        for action: KeyInterceptor.ReservedChord
    ) -> (Chord, KeyInterceptor.ReservedChord)? {
        KeymapDefaults.chords(of: action)
            .sorted { $0.configToken < $1.configToken }
            .lazy
            .compactMap { chord -> (Chord, KeyInterceptor.ReservedChord)? in
                guard let owner = GeneralConfig.current.keymap[chord], owner != action else { return nil }
                return (chord, owner)
            }
            .first
    }

    private func resetAll() {
        desired = KeymapOverrides(defaults: KeymapDefaults.map)
        guard persist(reportingRow: rows.last) else { return }
        resetAllMessage.flash("Defaults restored.")
    }

    @discardableResult
    private func persist(reportingRow: KeybindRow?) -> Bool {
        do {
            try ConfigWriter.apply(keybinds: desired)
        } catch {
            desired = KeymapOverrides(config: .current)
            refreshRows()
            (reportingRow ?? rows.first)?.showMessage(
                "Couldn't write config: \(error.localizedDescription)", kind: .failure)
            return false
        }
        AppConfig.reload()
        rows.filter { $0.messageKind == .failure }.forEach { $0.showMessage(nil) }
        desired = KeymapOverrides(config: .current)
        refreshRows()
        return true
    }

    /// Leaves `.failure` messages alone: a refresh doesn't resolve a write that failed.
    private func refreshRows() {
        let diagnostics = GeneralConfig.current.configDiagnostics
        for row in rows {
            row.render(currentShortcut: displayedChord(for: row.action)?.displayGlyph ?? "")
            guard row.messageKind != .failure else { continue }
            let diagnostic = diagnostics.first { $0.scope == .keybind(row.action) }
            row.showMessage(
                diagnostic?.message, kind: (diagnostic?.isChordConflict ?? false) ? .explanation : .diagnostic)
        }
    }

    private func showHint(for row: KeybindRow) {
        hideHint()
        guard let host = detailScroll?.superview else { return }
        let backdrop = BackdropView { [weak self] in self?.cancelCapture() }
        backdrop.frame = host.bounds
        backdrop.autoresizingMask = [.width, .height]
        host.addSubview(backdrop)
        hintBackdrop = backdrop
        let bubble = KeybindHintBubble()
        let conflict = KeybindConflict.all(in: GeneralConfig.current).first { $0.loser == row.action }
        bubble.setCanResetToDefault(conflict.map(\.isRevertable) ?? !isAtDefault(row.action))
        bubble.onResetToDefault = { [weak self, weak row] in
            guard let self, let row else { return }
            self.endCapture(row)
            self.reset(row)
        }
        bubble.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(bubble)
        hintBubble = bubble
        positionBubble(for: row)
    }

    private func cancelCapture() {
        guard let row = capturingRow else { hideHint(); return }
        endCapture(row)
        refreshRows()
    }

    private func positionBubble(for row: KeybindRow) {
        guard let bubble = hintBubble, let host = bubble.superview else { return }
        bubble.layoutSubtreeIfNeeded()
        let size = bubble.fittingSize
        let chipRect = row.chip.convert(row.chip.bounds, to: host)
        let x = max(8, min(chipRect.midX - size.width / 2, host.bounds.width - size.width - 8))
        let primary = host.isFlipped ? (chipRect.maxY + 6) : (chipRect.minY - size.height - 6)
        let fallback = host.isFlipped ? (chipRect.minY - size.height - 6) : (chipRect.maxY + 6)
        let maxY = max(8, host.bounds.height - size.height - 8)
        var y = primary
        if y < 8 || y > maxY { y = fallback }
        y = max(8, min(y, maxY))
        bubble.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func hideHint() {
        hintBubble?.removeFromSuperview()
        hintBubble = nil
        hintBackdrop?.removeFromSuperview()
        hintBackdrop = nil
        capturingRow = nil
        if hasMissedConfigReload { refreshFromConfig() }
    }

    private static func modifierGlyph(_ flags: NSEvent.ModifierFlags) -> String {
        Chord.modifierGlyph(flags)
    }

    private func displayedChord(for action: KeyInterceptor.ReservedChord) -> Chord? {
        Chord.displayed(action, in: desired.binds)
    }

    private func moveFocus(from view: NSView, delta: Int) {
        let stops = rows.map(\.chip) + [resetAllButton]
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta) { [rows] target in
            rows.first { $0.chip === target } ?? target
        }
    }

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
