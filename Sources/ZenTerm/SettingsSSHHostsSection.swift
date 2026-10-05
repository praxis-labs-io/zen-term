import AppKit

final class SettingsSSHHostsSection: SettingsSection {
    var navTitle: String { "SSH Hosts" }
    var onExitToNav: (() -> Void)?
    var onAddHost: (() -> Void)?
    var onEditHost: ((SSHHostEntry, _ address: String?) -> Void)?
    var initialFocus: Focus?
    var statusCenter = SSHHostStatusCenter.shared

    enum Focus {
        case host(String)
        case addHost
    }

    private enum Stop: Equatable {
        case row(String)
        case add
    }

    private var shownAddresses: [String: String] = [:]
    private var shownEntries: [SSHHostEntry] = []
    private var statusObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    private var hostRows: [SSHHostRow] = []
    private let addButton = AppButton(title: "＋ Add Host…", variant: .muted)
    private var caption: NSTextField?
    private var emptyNote: NSTextField?
    private var rowsStack: NSStackView?

    deinit {
        statusObserver.map(NotificationCenter.default.removeObserver)
        configObserver.map(NotificationCenter.default.removeObserver)
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

        observeStatuses()
        observeHostList()
        populate()
        focusInitialStop()
        return SettingsDetail.scroll(for: stack)
    }

    func detailStops() -> [NSView] { hostRows + [addButton] }

    func reapplyTheme() {
        caption?.textColor = Theme.current.chrome.ink(.muted)
        emptyNote?.textColor = Theme.current.chrome.ink(.muted)
        hostRows.forEach { $0.reapplyTheme() }
        addButton.reapplyTheme()
    }

    private func focusInitialStop() {
        guard let initialFocus else { return }
        self.initialFocus = nil
        let stop: Stop =
            switch initialFocus {
            case .host(let host): .row(host)
            case .addHost: .add
            }
        DispatchQueue.main.async { [weak self] in self?.focus(stop) }
    }

    private func observeStatuses() {
        statusObserver.map(NotificationCenter.default.removeObserver)
        statusObserver = NotificationCenter.default.addObserver(
            forName: .sshHostStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.addresses() != self.shownAddresses { return self.populate() }
                self.hostRows.forEach { $0.setStatus(self.status(of: $0.host)) }
            }
        }
    }

    private func observeHostList() {
        configObserver.map(NotificationCenter.default.removeObserver)
        configObserver = NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard ConfigChange.from(note).contains(.sshHosts) else { return }
            MainActor.assumeIsolated { self?.refreshHostList() }
        }
    }

    private func refreshHostList() {
        guard GeneralConfig.current.sshHosts != shownEntries else { return }
        populate()
    }

    private func status(of host: String) -> SSHHostStatus { statusCenter.status(of: SSHHostID(alias: host)) }

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
        emptyNote = nil

        addCaption("SSH Hosts", to: stack)
        shownEntries = GeneralConfig.current.sshHosts
        if shownEntries.isEmpty { addNote("No SSH hosts yet. Add one below.", to: stack) }
        for host in shownEntries.map(\.alias) { add(makeRow(host), to: stack) }

        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        shownAddresses = addresses()
        restore.map(focus)
    }

    private func addCaption(_ title: String, to stack: NSStackView) {
        let label = SettingsDetail.groupCaption(title)
        caption = label
        let header = SettingsDetail.headerRow(caption: label, hint: nil)
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
        emptyNote = note
        stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func add(_ row: SSHHostRow, to stack: NSStackView) {
        hostRows.append(row)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func entry(of host: String) -> SSHHostEntry {
        GeneralConfig.current.sshHosts.first { $0.alias == host } ?? SSHHostEntry(alias: host)
    }

    private func description(of host: String) -> String? {
        let address = address(of: host)
        guard entry(of: host).name != nil else { return address }
        return address.map { "\(host) · \($0)" } ?? host
    }

    private func makeRow(_ host: String) -> SSHHostRow {
        let row = SSHHostRow(
            host: host, title: entry(of: host).displayName, subtitle: description(of: host),
            status: status(of: host))
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

    private func focusedStop() -> Stop? {
        let window = rowsStack?.window
        if KeyboardFocus.isFocused(addButton, in: window) { return .add }
        return hostRows.first { KeyboardFocus.isFocused($0, in: window) }.map { .row($0.host) }
    }

    private func focus(_ stop: Stop) {
        let target: NSView? =
            switch stop {
            case .add: addButton
            case .row(let host): hostRows.first { $0.host == host }
            }
        guard let target = target ?? detailStops().first else { return }
        rowsStack?.window?.makeFirstResponder(target)
        KeyboardFocus.reveal(target, among: detailStops())
    }

    private func moveFocus(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = detailStops()
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta) { $0 }
    }

    private func moveTab(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = detailStops()
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        if delta < 0, anchor == 0 {
            onExitToNav?()
            return
        }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta, wrap: true) { $0 }
    }
}
