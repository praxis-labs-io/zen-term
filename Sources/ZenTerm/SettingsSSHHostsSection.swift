import AppKit

final class SettingsSSHHostsSection: SettingsSection {
    var navTitle: String { "SSH Hosts" }
    var onExitToNav: (() -> Void)?
    var onAddHost: (() -> Void)?

    private struct Listed {
        let host: String
        let isTyped: Bool
    }

    private struct HostRow {
        let host: String
        let row: LayoutRow
        let toggle: SegmentedControl
    }

    private enum Stop: Equatable {
        case host(String)
        case add
    }

    private var listed: [Listed]?
    private var destinations: [String: String] = [:]
    private var hostRows: [HostRow] = []
    private let addButton = AppButton(title: "＋ Add Host…", variant: .muted)
    private weak var caption: NSTextField?
    private weak var emptyHint: NSTextField?
    private var rowsStack: NSStackView?
    private var mountGeneration = 0

    private static let loadQueue = DispatchQueue(label: "com.zenterm.ssh-config-load", qos: .userInitiated)

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

    func detailStops() -> [NSView] { hostRows.map(\.toggle) + [addButton] }

    func reapplyTheme() {
        caption?.textColor = Theme.current.chrome.ink(.muted)
        emptyHint?.textColor = Theme.current.chrome.ink(.muted)
        for hostRow in hostRows {
            hostRow.row.reapplyTheme()
            hostRow.toggle.reapplyTheme()
        }
        addButton.reapplyTheme()
    }

    private func load() {
        listed = nil
        destinations = [:]
        populate()
        mountGeneration += 1
        let generation = mountGeneration
        let file = SSHConfigHosts.userConfig
        Self.loadQueue.async { [weak self] in
            let aliases = SSHConfigHosts.aliases(in: file)
            DispatchQueue.main.async {
                guard let self, generation == self.mountGeneration else { return }
                self.land(aliases, generation: generation)
            }
        }
    }

    private func land(_ aliases: [String], generation: Int) {
        let typed = GeneralConfig.current.sshHosts.filter { !aliases.contains($0) }
        let list = aliases.map { Listed(host: $0, isTyped: false) } + typed.map { Listed(host: $0, isTyped: true) }
        listed = list
        populate()
        SSHHostResolver.destinations(of: list.map(\.host)) { [weak self] found in
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

        let caption = SettingsDetail.groupCaption("SSH Hosts")
        self.caption = caption
        let header = SettingsDetail.headerRow(caption: caption, hint: nil)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if let listed, listed.isEmpty {
            let hint = NSTextField(
                labelWithString: "No SSH hosts yet. Add one, or add a Host entry to ~/.ssh/config.")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = Theme.current.chrome.ink(.muted)
            hint.lineBreakMode = .byWordWrapping
            hint.maximumNumberOfLines = 0
            emptyHint = hint
            stack.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else if let listed {
            let enabled = GeneralConfig.current.sshHosts
            for entry in listed {
                let hostRow = makeRow(entry, isOn: enabled.contains(entry.host))
                hostRows.append(hostRow)
                stack.addArrangedSubview(hostRow.row)
                hostRow.row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        restore.map(focus)
    }

    private func makeRow(_ entry: Listed, isOn: Bool) -> HostRow {
        let host = entry.host
        let toggle = SegmentedControl(options: ["On", "Off"], selectedIndex: isOn ? 0 : 1) { _ in }
        let destination = destinations[host].flatMap { $0 == host ? nil : $0 }
        let row = LayoutRow(
            caption: host, description: destination, control: toggle, controlNote: nil, controlWidth: nil)
        toggle.onChange = { [weak self, weak row, weak toggle] index in
            guard let row, let toggle else { return }
            self?.turn(host, on: index == 0, row: row, toggle: toggle)
        }
        toggle.onArrowUp = { [weak self, weak toggle] in self?.moveFocus(from: toggle, delta: -1) }
        toggle.onArrowDown = { [weak self, weak toggle] in self?.moveFocus(from: toggle, delta: 1) }
        toggle.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        toggle.onTab = { [weak self, weak toggle] in self?.moveTab(from: toggle, delta: 1) }
        toggle.onBacktab = { [weak self, weak toggle] in self?.moveTab(from: toggle, delta: -1) }
        if entry.isTyped {
            toggle.onDelete = { [weak self, weak row] in
                guard let row else { return }
                self?.remove(host, row: row)
            }
        }
        return HostRow(host: host, row: row, toggle: toggle)
    }

    private func turn(_ host: String, on: Bool, row: LayoutRow, toggle: SegmentedControl) {
        guard write(host, on: on, row: row) else {
            toggle.setSelection(on ? 1 : 0)
            return
        }
        row.showMessage(nil)
    }

    // Deferred a turn because the rebuild frees this row's control while its `keyDown` is on the stack.
    private func remove(_ host: String, row: LayoutRow) {
        DispatchQueue.main.async { [weak self, weak row] in
            guard let self, let row, var list = self.listed,
                let index = list.firstIndex(where: { $0.host == host }),
                self.write(host, on: false, row: row)
            else { return }
            list.remove(at: index)
            self.listed = list
            let neighbour = list.indices.contains(index) ? list[index] : list.last
            self.populate(focusing: neighbour.map { .host($0.host) } ?? .add)
        }
    }

    private func write(_ host: String, on: Bool, row: LayoutRow) -> Bool {
        do {
            try SSHHostsWriter.set(host, on: on)
        } catch {
            row.showMessage("Couldn't write config: \(error.localizedDescription)")
            return false
        }
        AppConfig.reload()
        return true
    }

    private func focusedStop() -> Stop? {
        let window = rowsStack?.window
        if KeyboardFocus.isFocused(addButton, in: window) { return .add }
        return hostRows.first { KeyboardFocus.isFocused($0.toggle, in: window) }.map { .host($0.host) }
    }

    private func focus(_ stop: Stop) {
        let target: NSView? =
            switch stop {
            case .add: addButton
            case .host(let host): hostRows.first { $0.host == host }?.toggle
            }
        guard let target = target ?? detailStops().first else { return }
        rowsStack?.window?.makeFirstResponder(target)
        KeyboardFocus.reveal(scrollTarget(target), among: detailStops())
    }

    private func scrollTarget(_ stop: NSView) -> NSView {
        hostRows.first { $0.toggle === stop }?.row ?? stop
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
