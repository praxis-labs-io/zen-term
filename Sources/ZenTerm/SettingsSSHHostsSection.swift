import AppKit

final class SettingsSSHHostsSection: SettingsSection {
    var navTitle: String { "SSH Hosts" }
    var onExitToNav: (() -> Void)?
    var onAddHost: (() -> Void)?
    var onEditHost: ((SSHHostEntry, _ address: String?) -> Void)?
    var hostToFocus: String?
    var hostSession: ((SSHHostID) -> SSHConnection.State?)?
    var presentConfirm: ((ConfirmCard) -> Void)?
    var dismissConfirm: ((@escaping () -> Void) -> Void)?
    var statusCenter = SSHHostStatusCenter.shared

    private struct HostRow {
        let host: String
        let row: SSHHostRow
        let removeButton: AppButton
    }

    private enum Stop: Equatable {
        case row(String)
        case remove(String)
        case add
    }

    private var shownAddresses: [String: String] = [:]
    private var statusObserver: NSObjectProtocol?
    private var listed: [String] = []
    private var removed: Set<String> = []
    private var removedEntries: [String: SSHHostEntry] = [:]
    private var orderBeforeRemovals: [String]?
    private var hostRows: [HostRow] = []
    private let addButton = AppButton(title: "＋ Add Host…", variant: .muted)
    private var captions: [NSTextField] = []
    private var notes: [NSTextField] = []
    private var rowsStack: NSStackView?

    deinit {
        statusObserver.map(NotificationCenter.default.removeObserver)
    }

    // Focus stays on Remove once it reads Undo, so a held Return would flip the host back and forth.
    private static var isKeyRepeat: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    func makeDetailView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack = stack

        addButton.isKeyboardFocusable = true
        addButton.onArrowUp = { [weak self] in self?.moveFocus(from: self?.addButton, delta: -1) }
        addButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        addButton.onTab = { [weak self] in self?.moveTab(from: self?.addButton, delta: 1) }
        addButton.onBacktab = { [weak self] in self?.moveTab(from: self?.addButton, delta: -1) }
        addButton.onTap = { [weak self] in self?.onAddHost?() }

        observeAddresses()
        listed = GeneralConfig.current.sshHostAliases
        populate()
        focusPendingHost()
        return SettingsDetail.scroll(for: stack)
    }

    func detailStops() -> [NSView] { hostRows.flatMap(stops(of:)) + [addButton] }

    func reapplyTheme() {
        captions.forEach { $0.textColor = Theme.current.chrome.ink(.muted) }
        notes.forEach { $0.textColor = Theme.current.chrome.ink(.muted) }
        for hostRow in hostRows {
            hostRow.row.reapplyTheme()
            hostRow.removeButton.reapplyTheme()
        }
        addButton.reapplyTheme()
    }

    private func focusPendingHost() {
        guard let host = hostToFocus else { return }
        hostToFocus = nil
        DispatchQueue.main.async { [weak self] in self?.focus(.row(host)) }
    }

    private func observeAddresses() {
        statusObserver.map(NotificationCenter.default.removeObserver)
        statusObserver = NotificationCenter.default.addObserver(
            forName: .sshHostStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.addresses() != self.shownAddresses else { return }
                self.populate()
            }
        }
    }

    private func address(of host: String) -> String? {
        statusCenter.destination(of: SSHHostID(alias: host)).flatMap { $0 == host ? nil : $0 }
    }

    private func addresses() -> [String: String] {
        hostRows.reduce(into: [:]) { $0[$1.host] = address(of: $1.host) }
    }

    private func populate(focusing target: Stop? = nil) {
        guard let stack = rowsStack else { return }
        let restore = target ?? focusedStop()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        hostRows = []
        captions = []
        notes = []

        addCaption("SSH Hosts", to: stack)
        if listed.isEmpty { addNote("No SSH hosts yet. Add one below.", to: stack) }
        for host in listed { add(makeRemoveRow(host), to: stack) }

        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        shownAddresses = addresses()
        restore.map(focus)
    }

    private func addCaption(_ title: String, to stack: NSStackView) {
        if let previous = stack.arrangedSubviews.last { stack.setCustomSpacing(18, after: previous) }
        let caption = SettingsDetail.groupCaption(title)
        captions.append(caption)
        let header = SettingsDetail.headerRow(caption: caption, hint: nil)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(10, after: header)
    }

    private func addNote(_ text: String, to stack: NSStackView) {
        let note = NSTextField(labelWithString: text)
        note.font = .systemFont(ofSize: 12)
        note.textColor = Theme.current.chrome.ink(.muted)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        notes.append(note)
        stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func add(_ hostRow: HostRow, to stack: NSStackView) {
        hostRows.append(hostRow)
        stack.addArrangedSubview(hostRow.row)
        hostRow.row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func entry(of host: String) -> SSHHostEntry {
        GeneralConfig.current.sshHosts.first { $0.alias == host } ?? restored(host)
    }

    private func label(of host: String) -> String { entry(of: host).displayName }

    private func description(of host: String) -> String? {
        let address = address(of: host)
        guard entry(of: host).name != nil else { return address }
        return address.map { "\(host) · \($0)" } ?? host
    }

    private func makeRemoveRow(_ host: String) -> HostRow {
        let button = AppButton(title: "Remove", variant: .secondary)
        button.isKeyboardFocusable = true
        let row = makeRow(host, control: button, isEditable: !removed.contains(host))
        button.onTap = { [weak self, weak row, weak button] in
            guard let self, let row, let button, !Self.isKeyRepeat else { return }
            self.toggleRemoval(of: host, row: row, button: button)
        }
        button.onArrowUp = { [weak self, weak button] in self?.moveFocus(from: button, delta: -1) }
        button.onArrowDown = { [weak self, weak button] in self?.moveFocus(from: button, delta: 1) }
        button.onArrowLeft = { [weak self, weak row] in self?.leaveControl(of: row) }
        button.onTab = { [weak self, weak button] in self?.moveTab(from: button, delta: 1) }
        button.onBacktab = { [weak self, weak button] in self?.moveTab(from: button, delta: -1) }
        row.onArrowRight = { [weak button] in if let button { button.window?.makeFirstResponder(button) } }
        showRemoval(removed.contains(host), of: host, row: row, button: button)
        return HostRow(host: host, row: row, removeButton: button)
    }

    private func makeRow(_ host: String, control: NSView, isEditable: Bool) -> SSHHostRow {
        let layout = LayoutRow(
            caption: label(of: host), description: description(of: host), control: control, controlNote: nil,
            controlWidth: Self.removalButtonWidth)
        let row = SSHHostRow(host: host, layout: layout, isEditable: isEditable)
        row.setAccessibilityLabel("Edit \(label(of: host))")
        row.onActivate = { [weak self] in self?.edit(host) }
        row.onArrowUp = { [weak self, weak row] in self?.moveFocus(from: row, delta: -1) }
        row.onArrowDown = { [weak self, weak row] in self?.moveFocus(from: row, delta: 1) }
        row.onTab = { [weak self, weak row] in self?.moveTab(from: row, delta: 1) }
        row.onBacktab = { [weak self, weak row] in self?.moveTab(from: row, delta: -1) }
        row.onExitToNav = { [weak self] in self?.onExitToNav?() }
        return row
    }

    private func edit(_ host: String) {
        onEditHost?(entry(of: host), address(of: host))
    }

    private func leaveControl(of row: SSHHostRow?) {
        guard let row, row.isEditable else {
            onExitToNav?()
            return
        }
        row.window?.makeFirstResponder(row)
    }

    private func toggleRemoval(of host: String, row: SSHHostRow, button: AppButton) {
        guard !removed.contains(host) else {
            guard save(row: row.layout, { try restore(host) }) else { return }
            removed.remove(host)
            return showRemoval(false, of: host, row: row, button: button)
        }
        confirmDisconnect(
            of: host,
            proceed: { [weak self] in
                guard let self else { return }
                let config = GeneralConfig.current
                self.removed.insert(host)
                guard self.save(row: row.layout, { try self.removeHost(host) }) else {
                    self.removed.remove(host)
                    return
                }
                if self.orderBeforeRemovals == nil { self.orderBeforeRemovals = config.sshHostAliases }
                self.showRemoval(true, of: host, row: row, button: button)
            })
    }

    private func confirmDisconnect(of host: String, proceed: @escaping () -> Void) {
        guard let session = hostSession?(SSHHostID(alias: host)), session != .failed, let presentConfirm,
            let dismissConfirm
        else { return proceed() }
        let consequence =
            session == .connected
            ? "disconnect it and stop everything running in it" : "stop connecting to it and close its tabs"
        presentConfirm(
            ConfirmCard(
                title: "Remove \(label(of: host))",
                message: "Removing \(label(of: host)) will \(consequence).",
                confirmLabel: "Remove", background: Theme.current.chrome.background.nsColor,
                onCancel: { [weak self] in
                    dismissConfirm { self?.focus(.remove(host)) }
                },
                onConfirm: { [weak self] in
                    dismissConfirm {
                        proceed()
                        self?.focus(.remove(host))
                    }
                }))
    }

    private func removeHost(_ host: String) throws {
        removedEntries[host] = entry(of: host)
        try SSHHostsWriter.remove(host)
    }

    private func restore(_ host: String) throws {
        let config = GeneralConfig.current
        let index = restoredIndex(of: host, order: orderBeforeRemovals, among: config.sshHostAliases)
        try SSHHostsWriter.add(restored(host), at: index)
    }

    private func restored(_ host: String) -> SSHHostEntry { removedEntries[host] ?? SSHHostEntry(alias: host) }

    private func restoredIndex(of host: String, order: [String]?, among enabled: [String]) -> Int {
        guard let order, let position = order.firstIndex(of: host) else { return enabled.count }
        let next = order[(position + 1)...].first { enabled.contains($0) }
        return next.flatMap { enabled.firstIndex(of: $0) } ?? enabled.count
    }

    // Fits either title so the button keeps its edge when Remove turns into Undo.
    private static let removalButtonWidth: CGFloat =
        ["Remove", "Undo"].map {
            AppButton(title: $0, variant: .secondary).fittingSize.width
        }.max() ?? 0

    private func showRemoval(_ isRemoved: Bool, of host: String, row: SSHHostRow, button: AppButton) {
        row.layout.isDimmed = isRemoved
        row.isEditable = !isRemoved
        button.setTitle(isRemoved ? "Undo" : "Remove")
        button.setAccessibilityLabel(isRemoved ? "Undo removing \(label(of: host))" : "Remove \(label(of: host))")
    }

    private func save(row: LayoutRow, _ change: () throws -> Void) -> Bool {
        do {
            try change()
        } catch {
            row.showMessage("Couldn't save ZenTerm's config: \(error.localizedDescription)")
            return false
        }
        AppConfig.reload()
        row.showMessage(nil)
        return true
    }

    private func stops(of hostRow: HostRow) -> [NSView] {
        (hostRow.row.isEditable ? [hostRow.row] : []) + [hostRow.removeButton]
    }

    private func focusedStop() -> Stop? {
        let window = rowsStack?.window
        if KeyboardFocus.isFocused(addButton, in: window) { return .add }
        for hostRow in hostRows {
            if KeyboardFocus.isFocused(hostRow.row, in: window) { return .row(hostRow.host) }
            if KeyboardFocus.isFocused(hostRow.removeButton, in: window) { return .remove(hostRow.host) }
        }
        return nil
    }

    private func focus(_ stop: Stop) {
        let target: NSView? =
            switch stop {
            case .add: addButton
            case .row(let host): hostRows.first { $0.host == host }.flatMap { stops(of: $0).first }
            case .remove(let host): hostRows.first { $0.host == host }?.removeButton
            }
        guard let target = target ?? detailStops().first else { return }
        rowsStack?.window?.makeFirstResponder(target)
        KeyboardFocus.reveal(scrollTarget(target), among: detailStops())
    }

    private func scrollTarget(_ stop: NSView) -> NSView {
        hostRows.first { $0.removeButton === stop || $0.row === stop }?.row ?? stop
    }

    private func arrowColumn(from view: NSView) -> [NSView] {
        let onControl = hostRows.contains { $0.removeButton === view }
        return hostRows.compactMap { onControl ? $0.removeButton : stops(of: $0).first } + [addButton]
    }

    private func moveFocus(from view: NSView?, delta: Int) {
        guard let view else { return }
        let column = arrowColumn(from: view)
        guard let anchor = column.firstIndex(where: { $0 === view }) else { return }
        SettingsDetail.moveFocus(stops: column, from: anchor, delta: delta) { [weak self] in
            self?.scrollTarget($0) ?? $0
        }
    }

    private func moveTab(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = detailStops()
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        if delta < 0, anchor == 0 {
            onExitToNav?()
            return
        }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta, wrap: true) { [weak self] in
            self?.scrollTarget($0) ?? $0
        }
    }
}
