import AppKit

final class SettingsSSHHostsSection: SettingsSection {
    var navTitle: String { "SSH Hosts" }
    var onExitToNav: (() -> Void)?
    var onAddHost: (() -> Void)?
    var hostToFocus: String?
    var hostSession: ((SSHHostID) -> SSHConnection.State?)?
    var presentConfirm: ((ConfirmCard) -> Void)?
    var dismissConfirm: ((@escaping () -> Void) -> Void)?

    private struct Listing {
        let aliases: [String]
        let typed: [String]
        let isConfigUnreadable: Bool

        var isEmpty: Bool { aliases.isEmpty && typed.isEmpty && !isConfigUnreadable }
    }

    private enum HostControl {
        case toggle(SegmentedControl)
        case remove(AppButton)

        var view: NSView {
            switch self {
            case .toggle(let toggle): toggle
            case .remove(let button): button
            }
        }
    }

    private struct HostRow {
        let host: String
        let row: LayoutRow
        let control: HostControl
    }

    private enum Disconnecting {
        case turningOff, removing

        var action: String { self == .turningOff ? "Turn Off" : "Remove" }
        var gerund: String { self == .turningOff ? "Turning off" : "Removing" }
    }

    private enum Stop: Equatable {
        case host(String)
        case add
    }

    private var listing: Listing?
    private var destinations: [String: String] = [:]
    private var removed: Set<String> = []
    private var orderBeforeRemovals: [String]?
    private var hostRows: [HostRow] = []
    private let addButton = AppButton(title: "＋ Add Host…", variant: .muted)
    private var captions: [NSTextField] = []
    private var notes: [NSTextField] = []
    private var rowsStack: NSStackView?
    private var mountGeneration = 0

    private static let loadQueue = DispatchQueue(label: "com.zenterm.ssh-config-load", qos: .userInitiated)

    // Focus stays on Remove once it reads Undo, so a held Return would flip the host back and forth.
    private static var isKeyRepeat: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    func makeDetailView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack = stack

        addButton.isKeyboardFocusable = true
        addButton.onArrowUp = { [weak self] in self?.moveFocus(from: self?.addButton, delta: -1) }
        addButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        addButton.onTab = { [weak self] in self?.moveTab(from: self?.addButton, delta: 1) }
        addButton.onBacktab = { [weak self] in self?.moveTab(from: self?.addButton, delta: -1) }
        addButton.onTap = { [weak self] in self?.onAddHost?() }

        load()
        return SettingsDetail.scroll(for: stack)
    }

    func detailStops() -> [NSView] { hostRows.map(\.control.view) + [addButton] }

    func reapplyTheme() {
        captions.forEach { $0.textColor = Theme.current.chrome.ink(.muted) }
        notes.forEach { $0.textColor = Theme.current.chrome.ink(.muted) }
        for hostRow in hostRows {
            hostRow.row.reapplyTheme()
            switch hostRow.control {
            case .toggle(let toggle): toggle.reapplyTheme()
            case .remove(let button): button.reapplyTheme()
            }
        }
        addButton.reapplyTheme()
    }

    private func load() {
        listing = nil
        destinations = [:]
        removed = []
        orderBeforeRemovals = nil
        populate()
        mountGeneration += 1
        let generation = mountGeneration
        let file = SSHConfigHosts.userConfig
        Self.loadQueue.async { [weak self] in
            let config = SSHConfigHosts.listing(of: file)
            DispatchQueue.main.async {
                guard let self, generation == self.mountGeneration else { return }
                self.land(config, generation: generation)
            }
        }
    }

    private func land(_ config: SSHConfigHosts.Listing, generation: Int) {
        let typed = GeneralConfig.current.sshHosts.filter { !config.aliases.contains($0) }
        listing = Listing(aliases: config.aliases, typed: typed, isConfigUnreadable: config.isUnreadable)
        populate(focusing: hostToFocus.map { .host($0) })
        hostToFocus = nil
        SSHHostResolver.destinations(of: config.aliases + typed) { [weak self] found in
            guard let self, generation == self.mountGeneration, !found.isEmpty else { return }
            self.destinations = found
            self.populate()
        }
    }

    private func populate(focusing target: Stop? = nil) {
        guard let stack = rowsStack else { return }
        let restore = target ?? focusedStop()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        hostRows = []
        captions = []
        notes = []

        if let listing, !listing.isEmpty {
            if !listing.aliases.isEmpty || listing.isConfigUnreadable {
                addCaption("SSH config", to: stack)
                if listing.isConfigUnreadable { addNote("Couldn't read ~/.ssh/config.", to: stack) }
                let enabled = GeneralConfig.current.sshHosts
                for alias in listing.aliases { add(makeToggleRow(alias, isOn: enabled.contains(alias)), to: stack) }
            }
            if !listing.typed.isEmpty {
                addCaption("Added hosts", to: stack)
                for host in listing.typed { add(makeRemoveRow(host), to: stack) }
            }
        } else {
            addCaption("SSH Hosts", to: stack)
            if listing != nil {
                addNote("No SSH hosts yet. Add one, or add a Host entry to ~/.ssh/config.", to: stack)
            }
        }

        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        restore.map(focus)
    }

    private func addCaption(_ title: String, to stack: NSStackView) {
        if let previous = stack.arrangedSubviews.last { stack.setCustomSpacing(18, after: previous) }
        let caption = SettingsDetail.groupCaption(title)
        captions.append(caption)
        let header = SettingsDetail.headerRow(caption: caption, hint: nil)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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

    private func destination(of host: String) -> String? {
        destinations[host].flatMap { $0 == host ? nil : $0 }
    }

    private func makeToggleRow(_ host: String, isOn: Bool) -> HostRow {
        let toggle = SegmentedControl(options: ["On", "Off"], selectedIndex: isOn ? 0 : 1) { _ in }
        let row = LayoutRow(
            caption: host, description: destination(of: host), control: toggle, controlNote: nil, controlWidth: nil)
        toggle.onChange = { [weak self, weak row, weak toggle] index in
            guard let row, let toggle else { return }
            self?.turn(host, on: index == 0, row: row, toggle: toggle)
        }
        toggle.onArrowUp = { [weak self, weak toggle] in self?.moveFocus(from: toggle, delta: -1) }
        toggle.onArrowDown = { [weak self, weak toggle] in self?.moveFocus(from: toggle, delta: 1) }
        toggle.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        toggle.onTab = { [weak self, weak toggle] in self?.moveTab(from: toggle, delta: 1) }
        toggle.onBacktab = { [weak self, weak toggle] in self?.moveTab(from: toggle, delta: -1) }
        return HostRow(host: host, row: row, control: .toggle(toggle))
    }

    private func makeRemoveRow(_ host: String) -> HostRow {
        let button = AppButton(title: "Remove", variant: .secondary)
        button.isKeyboardFocusable = true
        let row = LayoutRow(
            caption: host, description: destination(of: host), control: button, controlNote: nil,
            controlWidth: Self.removalButtonWidth)
        button.onTap = { [weak self, weak row, weak button] in
            guard let self, let row, let button, !Self.isKeyRepeat else { return }
            self.toggleRemoval(of: host, row: row, button: button)
        }
        button.onArrowUp = { [weak self, weak button] in self?.moveFocus(from: button, delta: -1) }
        button.onArrowDown = { [weak self, weak button] in self?.moveFocus(from: button, delta: 1) }
        button.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        button.onTab = { [weak self, weak button] in self?.moveTab(from: button, delta: 1) }
        button.onBacktab = { [weak self, weak button] in self?.moveTab(from: button, delta: -1) }
        showRemoval(removed.contains(host), of: host, row: row, button: button)
        return HostRow(host: host, row: row, control: .remove(button))
    }

    private func turn(_ host: String, on: Bool, row: LayoutRow, toggle: SegmentedControl) {
        let save = { [weak self] in
            guard let self else { return }
            if !self.save(row: row, { try SSHHostsWriter.set(host, on: on) }) { toggle.setSelection(on ? 1 : 0) }
        }
        guard !on else { return save() }
        confirmDisconnect(
            of: host, by: .turningOff, proceed: save,
            cancel: { toggle.setSelection(0) })
    }

    private func toggleRemoval(of host: String, row: LayoutRow, button: AppButton) {
        guard !removed.contains(host) else {
            let index = restoredIndex(of: host)
            guard save(row: row, { try SSHHostsWriter.insert(host, at: index) }) else { return }
            removed.remove(host)
            return showRemoval(false, of: host, row: row, button: button)
        }
        confirmDisconnect(
            of: host, by: .removing,
            proceed: { [weak self] in
                guard let self else { return }
                let enabled = GeneralConfig.current.sshHosts
                guard self.save(row: row, { try SSHHostsWriter.set(host, on: false) }) else { return }
                if self.orderBeforeRemovals == nil { self.orderBeforeRemovals = enabled }
                self.removed.insert(host)
                self.showRemoval(true, of: host, row: row, button: button)
            }, cancel: {})
    }

    private func confirmDisconnect(
        of host: String, by disconnecting: Disconnecting, proceed: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        guard let session = hostSession?(SSHHostID(name: host)), session != .failed, let presentConfirm,
            let dismissConfirm
        else { return proceed() }
        let consequence =
            session == .connected
            ? "disconnect it and stop everything running in it" : "stop connecting to it and close its tabs"
        presentConfirm(
            ConfirmCard(
                title: "\(disconnecting.action) \(host)",
                message: "\(disconnecting.gerund) \(host) will \(consequence).",
                confirmLabel: disconnecting.action, background: Theme.current.chrome.background.nsColor,
                onCancel: { [weak self] in
                    dismissConfirm {
                        cancel()
                        self?.focus(.host(host))
                    }
                },
                onConfirm: { [weak self] in
                    dismissConfirm {
                        proceed()
                        self?.focus(.host(host))
                    }
                }))
    }

    private func restoredIndex(of host: String) -> Int {
        let enabled = GeneralConfig.current.sshHosts
        guard let order = orderBeforeRemovals, let position = order.firstIndex(of: host) else { return enabled.count }
        let next = order[(position + 1)...].first { enabled.contains($0) }
        return next.flatMap { enabled.firstIndex(of: $0) } ?? enabled.count
    }

    // Fits either title so the button keeps its edge when Remove turns into Undo.
    private static let removalButtonWidth: CGFloat =
        ["Remove", "Undo"].map {
            AppButton(title: $0, variant: .secondary).fittingSize.width
        }.max() ?? 0

    private func showRemoval(_ isRemoved: Bool, of host: String, row: LayoutRow, button: AppButton) {
        row.isDimmed = isRemoved
        button.setTitle(isRemoved ? "Undo" : "Remove")
        button.setAccessibilityLabel(isRemoved ? "Undo removing \(host)" : "Remove \(host)")
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

    private func focusedStop() -> Stop? {
        let window = rowsStack?.window
        if KeyboardFocus.isFocused(addButton, in: window) { return .add }
        return hostRows.first { KeyboardFocus.isFocused($0.control.view, in: window) }.map { .host($0.host) }
    }

    private func focus(_ stop: Stop) {
        let target: NSView? =
            switch stop {
            case .add: addButton
            case .host(let host): hostRows.first { $0.host == host }?.control.view
            }
        guard let target = target ?? detailStops().first else { return }
        rowsStack?.window?.makeFirstResponder(target)
        KeyboardFocus.reveal(scrollTarget(target), among: detailStops())
    }

    private func scrollTarget(_ stop: NSView) -> NSView {
        hostRows.first { $0.control.view === stop }?.row ?? stop
    }

    private func moveFocus(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = detailStops()
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta) { [weak self] in
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
