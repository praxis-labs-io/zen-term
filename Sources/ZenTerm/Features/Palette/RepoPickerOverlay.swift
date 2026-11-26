import AppKit
import AppLog
import TerminalKit

final class RepoPickerOverlay: PaletteOverlay {
    private enum Row {
        case newWorkspace
        case open(RunningWorkspace)
        case elsewhere(RunningWorkspace)
        case closedParent(RunningWorkspace, entry: Workspace?)
        case add
        case workspace(Workspace)
        case worktree(Worktree, parent: Workspace)
        case host(SSHHostID)
    }

    static let newHintLabel = "New"

    enum State: String {
        case current = "Current"
        case open = "Open"
        case otherWindow = "Other window"
    }

    private let onChoose: (Workspace, WorktreeOrigin?) -> Void
    private let onSwitch: (WorkspaceID) -> Void
    private let onReveal: (Int, WorkspaceID) -> Bool
    private let openState: (URL) -> WorkspaceOpenState
    private let onAddWorkspace: () -> Void
    private let onNewWorkspace: (String?) -> Void
    private let onActivateHost: (SSHHostID) -> Void

    private let entries: [Workspace]
    private let hosts: [SSHHostID]
    private let currentHost: SSHHostID?
    private let hostOpenState: (SSHHostID) -> WorkspaceOpenState
    private var open: [RunningWorkspace]
    private var elsewhere: [RunningWorkspace]
    private var current: WorkspaceID?
    private var listings: [URL: WorktreeListing] = [:]

    /// Cancelled per picker, not queue-wide: another window's picker shares the queue.
    private var churnRefreshes: [GitRepoStatus.RefreshToken] = []
    private var churnProbed: Set<URL>
    private var worktreeRefresh: GitRepoStatus.RefreshToken?
    private var worktreeOwners: [URL: URL] = [:]
    private let configuredPaths: Set<URL>
    private var rows: [Row]
    private let removals: WorktreeRemovalTracker

    init(
        entries: [Workspace], open: [RunningWorkspace] = [], elsewhere: [RunningWorkspace] = [],
        current: WorkspaceID? = nil, hosts: [SSHHostID] = [], currentHost: SSHHostID? = nil,
        removals: WorktreeRemovalTracker = WorktreeRemovalTracker(),
        openState: @escaping (URL) -> WorkspaceOpenState = { _ in .closed },
        hostOpenState: @escaping (SSHHostID) -> WorkspaceOpenState = { _ in .closed },
        onChoose: @escaping (Workspace, WorktreeOrigin?) -> Void,
        onSwitch: @escaping (WorkspaceID) -> Void = { _ in },
        onReveal: @escaping (Int, WorkspaceID) -> Bool = { _, _ in false },
        onAddWorkspace: @escaping () -> Void,
        onNewWorkspace: @escaping (String?) -> Void = { _ in },
        onActivateHost: @escaping (SSHHostID) -> Void = { _ in }, onDismiss: @escaping () -> Void
    ) {
        self.entries = entries
        self.hosts = hosts
        self.currentHost = currentHost
        self.hostOpenState = hostOpenState
        self.open = open
        self.elsewhere = elsewhere
        self.current = current
        self.removals = removals
        self.configuredPaths = Set(entries.map { $0.path.standardizedFileURL })
        self.churnProbed = []
        self.rows = Self.list(
            Self.groups(
                open: open, elsewhere: elsewhere, entries: entries, hosts: hosts, listings: [:], configured: [],
                owners: [:]),
            query: nil)
        self.onChoose = onChoose
        self.onSwitch = onSwitch
        self.onReveal = onReveal
        self.openState = openState
        self.onAddWorkspace = onAddWorkspace
        self.onNewWorkspace = onNewWorkspace
        self.onActivateHost = onActivateHost
        super.init(
            placeholder: "Search workspaces",
            emptyText: "",
            onDismiss: onDismiss)

        let probes = configuredPaths.union((open + elsewhere).map { $0.folder.standardizedFileURL })
        churnProbed = probes
        GitRepoStatus.refresh(Array(probes)) { [weak self] in self?.rebuild() }
        refreshChurn(Array(probes))
        relistWorktrees()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func relistWorktrees() {
        worktreeRefresh?.cancel()
        worktreeRefresh = GitRepoStatus.refreshWorktrees(entries.map(\.path)) {
            [weak self] path, listing in
            self?.setWorktrees(listing, for: path)
        }
    }

    deinit {
        for token in churnRefreshes { token.cancel() }
        worktreeRefresh?.cancel()
    }

    private func refreshChurn(_ paths: [URL]) {
        guard !paths.isEmpty else { return }
        churnRefreshes.append(
            GitRepoStatus.refreshChurn(paths) { [weak self] in self?.applyGitStatus() })
    }

    private func applyGitStatus() {
        for row in rowViews { (row as? RowView)?.applyGitStatus() }
    }

    // Placement reads `GitRepoStatus.repoRoot`, which arrives off-main, so a late probe re-places rows.
    private func rebuild(animated: Bool = true) {
        let heldIndex = selected
        let held = rows.indices.contains(heldIndex) ? rowIdentity(at: heldIndex) : nil
        applyFilter(query: currentQuery)
        refreshRows(animated: animated)
        reselect(byIdentity: held, near: heldIndex)
        applyGitStatus()
    }

    func setWorktrees(_ listing: WorktreeListing, for workspacePath: URL) {
        listings[workspacePath.standardizedFileURL] = listing
        let unprobed = listing.worktrees.map(\.path.standardizedFileURL).filter {
            churnProbed.insert($0).inserted
        }
        refreshChurn(unprobed)
        worktreeOwners = Self.owners(among: entries, listings: listings)
        rebuild()
    }

    /// Decided from config order, never the filtered list, so a query can't move a worktree to another parent.
    private static func owners(
        among workspaces: [Workspace], listings: [URL: WorktreeListing]
    ) -> [URL: URL] {
        var owners: [URL: URL] = [:]
        for workspace in workspaces {
            let path = workspace.path.standardizedFileURL
            guard let listing = listings[path], !listing.worktrees.isEmpty else { continue }
            let key = listing.commonDir ?? path
            if owners[key] == nil { owners[key] = path }
        }
        return owners
    }

    private enum Placement { case here, elsewhere, closed, host }

    private struct Group {
        let placement: Placement
        var rows: [Row]
    }

    // A worktree mirrors its parent's configuration, so its unopened siblings join the first group its parent leads.
    private static func groups(
        open: [RunningWorkspace], elsewhere: [RunningWorkspace], entries: [Workspace], hosts: [SSHHostID],
        listings: [URL: WorktreeListing], configured: Set<URL>, owners: [URL: URL]
    ) -> [Group] {
        let listed = listed(open, elsewhere)
        var placed: Set<URL> = []
        func entry(at folder: URL) -> Workspace? {
            entries.first { $0.path.standardizedFileURL == folder.standardizedFileURL }
        }
        func closedWorktrees(of parent: Workspace) -> [Row] {
            let path = parent.path.standardizedFileURL
            guard let listing = listings[path], owners[listing.commonDir ?? path] == path,
                placed.insert(path).inserted
            else { return [] }
            return listing.worktrees
                .filter {
                    !configured.contains($0.path.standardizedFileURL) && !isListed($0, parent: parent, among: listed)
                }
                .map { .worktree($0, parent: parent) }
        }

        var groups: [Group] = []
        var leads: Set<URL> = listed
        for (running, placement) in [(open, Placement.here), (elsewhere, .elsewhere)] {
            for members in grouped(running) {
                let lead = members[0]
                let folder = lead.folder.standardizedFileURL
                let parent = entry(at: folder)
                let opensParent = !leads.contains(folder)
                leads.insert(folder)
                var rows: [Row] = [
                    lead.id == nil ? .closedParent(lead, entry: opensParent ? parent : nil) : row(lead, placement)
                ]
                rows += members.dropFirst().map { row($0, placement) }
                if let parent { rows += closedWorktrees(of: parent) }
                groups.append(Group(placement: placement, rows: rows))
            }
        }
        for workspace in entries where !leads.contains(workspace.path.standardizedFileURL) {
            groups.append(Group(placement: .closed, rows: [.workspace(workspace)] + closedWorktrees(of: workspace)))
        }
        return groups + hosts.map { Group(placement: .host, rows: [.host($0)]) }
    }

    private static func row(_ running: RunningWorkspace, _ placement: Placement) -> Row {
        placement == .here ? .open(running) : .elsewhere(running)
    }

    private static func grouped(_ running: [RunningWorkspace]) -> [[RunningWorkspace]] {
        var groups: [[RunningWorkspace]] = []
        for row in running {
            if row.isWorktree, !groups.isEmpty {
                groups[groups.count - 1].append(row)
            } else {
                groups.append([row])
            }
        }
        return groups
    }

    private static func list(_ groups: [Group], query: String?) -> [Row] {
        guard let query else { return groups.flatMap(\.rows) + [.add] }
        return [.newWorkspace] + ranked(groups, matching: query).flatMap { $0 } + [.add]
    }

    // Ranks within each placement, so a worktree never leaves its parent and an open group never drops below a closed one.
    private static func ranked(_ groups: [Group], matching query: String) -> [[Row]] {
        let scored = groups.compactMap { group -> (placement: Placement, score: Int, title: String, rows: [Row])? in
            let lead = group.rows[0]
            let leadScore = score(lead, query)
            let children = Array(group.rows.dropFirst())
            let hits = leadScore != nil ? children : children.filter { score($0, query) != nil }
            guard let best = leadScore ?? hits.compactMap({ score($0, query) }).max() else { return nil }
            return (group.placement, best, title(of: lead), [lead] + hits)
        }
        return [Placement.here, .elsewhere, .closed, .host].flatMap { placement in
            scored.filter { $0.placement == placement }
                .enumerated()
                .sorted { a, b in
                    if a.element.score != b.element.score { return a.element.score > b.element.score }
                    guard placement == .closed else { return a.offset < b.offset }
                    return a.element.title.localizedCaseInsensitiveCompare(b.element.title) == .orderedAscending
                }
                .map(\.element.rows)
        }
    }

    private static func title(of row: Row) -> String {
        switch row {
        case .closedParent(_, let entry?), .workspace(let entry): return entry.title
        case .open(let running), .elsewhere(let running), .closedParent(let running, nil): return running.name
        case .worktree(let worktree, _): return worktree.name
        case .host(let host): return GeneralConfig.current.displayName(of: host)
        case .newWorkspace, .add: return ""
        }
    }

    private static func score(_ row: Row, _ query: String) -> Int? {
        switch row {
        case .newWorkspace, .add: return nil
        case .closedParent(_, nil): return nil
        case .closedParent(_, let entry?), .workspace(let entry): return FuzzyMatch.score(query, entry.title)
        case .open(let running), .elsewhere(let running): return FuzzyMatch.score(query, running.name)
        case .worktree(let worktree, _): return score(worktree, query)
        case .host(let host):
            return [GeneralConfig.current.displayName(of: host), host.alias]
                .compactMap { FuzzyMatch.score(query, $0) }.max()
        }
    }

    // Fuzzy scores tie a whole name with a prefix of a longer one, so typing a name in full picks that row.
    private static func isNamed(_ row: Row, _ query: String) -> Bool {
        let names: [String]
        switch row {
        case .host(let host): names = [GeneralConfig.current.displayName(of: host), host.alias]
        case .newWorkspace, .add, .closedParent(_, nil): names = []
        default: names = [title(of: row)]
        }
        return names.contains { $0.caseInsensitiveCompare(query) == .orderedSame }
    }

    // An open worktree keeps no `Worktree` of its own, so its row resolves back through the listings.
    private func listedWorktree(at folder: URL) -> (worktree: Worktree, parent: Workspace)? {
        let target = folder.standardizedFileURL
        for workspace in entries {
            guard let listing = listings[workspace.path.standardizedFileURL] else { continue }
            for worktree in listing.worktrees {
                if worktree.path.standardizedFileURL == target { return (worktree, workspace) }
                if Self.mirror(of: workspace, in: worktree) == target { return (worktree, workspace) }
            }
        }
        return nil
    }

    // Built from every running row, never the filtered ones: a query must not make a workspace look closed.
    private static func listed(
        _ open: [RunningWorkspace], _ elsewhere: [RunningWorkspace]
    ) -> Set<URL> {
        Set((open + elsewhere).filter { $0.id != nil }.map { $0.folder.standardizedFileURL })
    }

    // A worktree is cut at the repo root, so the open row sits at the parent's mirrored subfolder inside it.
    private static func isListed(
        _ worktree: Worktree, parent: Workspace, among listed: Set<URL>
    ) -> Bool {
        listed.contains(worktree.path.standardizedFileURL)
            || listed.contains(mirror(of: parent, in: worktree))
    }

    // A worktree is cut at the repo root, so it also reads as open when the mirrored subfolder is.
    private static func worktreeOpenState(
        _ worktree: Worktree, parent: Workspace, openState: (URL) -> WorkspaceOpenState
    ) -> WorkspaceOpenState {
        .strongest([openState(mirror(of: parent, in: worktree)), openState(worktree.path)])
    }

    private static func mirror(of parent: Workspace, in worktree: Worktree) -> URL {
        GitRepo.mirrorPath(parent.path, from: GitRepoStatus.repoRoot(parent.path), into: worktree.path)
    }

    override func numberOfRows() -> Int { rows.count }

    // New Workspace holds the selection until a query matches something, so a search that finds nothing makes one.
    override func defaultSelectionIndex() -> Int {
        let selectable = rows.indices.filter { isSelectable(at: $0) }
        guard let query = newWorkspaceName else {
            let notCurrent = selectable.filter { state(at: $0) != .current }
            return notCurrent.first { state(at: $0) != nil } ?? notCurrent.first ?? selectable.first ?? 0
        }
        if let exact = selectable.first(where: { Self.isNamed(rows[$0], query) }) { return exact }
        let best = selectable.compactMap { index in Self.score(rows[index], query).map { (index, $0) } }
            .max { $0.1 < $1.1 }
        return best?.0 ?? selectable.first ?? 0
    }

    private func state(at index: Int) -> State? {
        switch rows[index] {
        case .open(let running): return running.id == current ? .current : .open
        case .elsewhere: return .otherWindow
        case .worktree(let worktree, let parent):
            switch Self.worktreeOpenState(worktree, parent: parent, openState: openState) {
            case .here: return .open
            case .elsewhere: return .otherWindow
            case .closed: return nil
            }
        case .host(let host):
            if host == currentHost { return .current }
            switch hostOpenState(host) {
            case .here: return .open
            case .elsewhere: return .otherWindow
            case .closed: return nil
            }
        default: return nil
        }
    }

    var newWorkspaceName: String? { newWorkspaceName(currentQuery) }

    private func newWorkspaceName(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    override func makeRow(at index: Int) -> PaletteRowView {
        switch rows[index] {
        case .newWorkspace:
            return ActionRowView(
                icon: .newWorkspace, title: newWorkspaceName.map { "New Workspace “\($0)”" } ?? "New Workspace",
                shortcut: Chord.displayed(.newWorkspace, in: GeneralConfig.current.keymap)?.displayGlyph,
                emphasis: .listed)
        case .add:
            return ActionRowView(icon: .addWorkspace, title: "Add Workspace…", shortcut: nil)
        case .open(let workspace), .elsewhere(let workspace):
            if let removing = removingWorktree(workspace) { return RemovingRowView(worktree: removing) }
            return RowView(open: workspace, state: state(at: index))
        case .closedParent(let running, let entry):
            return entry.map { RowView(workspace: $0) } ?? RowView(ghost: running)
        case .workspace(let workspace):
            return RowView(workspace: workspace)
        case .worktree(let worktree, let parent):
            guard !removals.isRemoving(worktree.path) else { return RemovingRowView(worktree: worktree) }
            return RowView(worktree: worktree, parent: parent, state: state(at: index))
        case .host(let host):
            return HostRowView(host: host, status: SSHHostStatusCenter.shared.status(of: host), state: state(at: index))
        }
    }

    private func openState(row: Row) -> WorkspaceOpenState {
        switch row {
        case .newWorkspace, .add, .closedParent, .host: return .closed
        case .open: return .here
        case .elsewhere: return .elsewhere
        case .workspace(let workspace): return openState(workspace.path)
        case .worktree(let worktree, let parent):
            return Self.worktreeOpenState(worktree, parent: parent, openState: openState)
        }
    }

    override func isSelectable(at index: Int) -> Bool {
        switch rows[index] {
        case .closedParent(_, let entry): return entry != nil
        case .open(let workspace), .elsewhere(let workspace): return removingWorktree(workspace) == nil
        case .worktree(let worktree, _): return !removals.isRemoving(worktree.path)
        case .newWorkspace, .add, .workspace, .host: return true
        }
    }

    func presentConfirm(_ card: ConfirmCard) { confirm.present(card) }

    override func focusInitialResponder() {
        if let card = confirm.card { card.focusInitialResponder() } else { focusQuery() }
    }

    func dismissConfirm() {
        confirm.dismiss { [weak self] in self?.focusQuery() }
    }

    #if DEBUG
        var presentedConfirmForTesting: ConfirmCard? { confirm.card }
    #endif

    func refreshOpen(_ running: [RunningWorkspace], elsewhere others: [RunningWorkspace], current: WorkspaceID?) {
        open = running
        elsewhere = others
        self.current = current
        rebuild()
    }

    func dropWorktree(at path: URL, open running: [RunningWorkspace]) {
        open = running
        elsewhere = Self.droppingOrphanedGhosts(elsewhere.filter { !GitRepo.isInside($0.folder, path) })
        let target = path.standardizedFileURL
        for (workspace, listing) in listings {
            listings[workspace] = WorktreeListing(
                commonDir: listing.commonDir,
                worktrees: listing.worktrees.filter { $0.path.standardizedFileURL != target })
        }
        worktreeOwners = Self.owners(among: entries, listings: listings)
        refreshRemovalState()
    }

    func refreshRemovalState() { rebuild() }

    // In place, so a probe flipping a host's reachability never replays its row's arrival.
    func refreshHostStatuses() {
        let hostRows = rowViews.compactMap { $0 as? HostRowView }
        for row in hostRows { row.setStatus(SSHHostStatusCenter.shared.status(of: row.host)) }
        let restated = rows.indices.contains { index in
            guard case .host(let host) = rows[index] else { return false }
            return hostRows.first { $0.host == host }?.state != state(at: index)
        }
        if restated { rebuild(animated: false) }
    }

    private func removingWorktree(_ running: RunningWorkspace) -> Worktree? {
        guard running.isWorktree, let found = listedWorktree(at: running.folder),
            removals.isRemoving(found.worktree.path)
        else { return nil }
        return found.worktree
    }

    private static func droppingOrphanedGhosts(_ rows: [RunningWorkspace]) -> [RunningWorkspace] {
        rows.indices.compactMap { index in
            let row = rows[index]
            guard row.id == nil else { return row }
            let next = rows.indices.contains(index + 1) ? rows[index + 1] : nil
            return next?.isWorktree == true && next?.window == row.window ? row : nil
        }
    }

    override func rowIdentity(at index: Int) -> AnyHashable? {
        switch rows[index] {
        case .newWorkspace: return ["new", newWorkspaceName ?? ""]
        case .add: return ["add"]
        case .closedParent(let running, let entry):
            return ["parent", "\(running.window)", running.folder.path, entry?.title ?? ""]
        case .open(let workspace):
            return [
                "open", "\(workspace.window)", "\(workspace.id?.raw ?? -1)", workspace.folder.path, workspace.name,
                removingWorktree(workspace) == nil ? "" : "removing", workspace.removedWorktreeName ?? "",
                state(at: index)?.rawValue ?? "",
            ]
        case .elsewhere(let workspace):
            return [
                "elsewhere", "\(workspace.window)", "\(workspace.id?.raw ?? -1)", workspace.folder.path, workspace.name,
                removingWorktree(workspace) == nil ? "" : "removing", workspace.removedWorktreeName ?? "",
            ]
        case .workspace(let workspace): return ["workspace", workspace.title]
        case .worktree(let worktree, _):
            return [
                "worktree", worktree.path.path, removals.isRemoving(worktree.path) ? "removing" : "",
                state(at: index)?.rawValue ?? "",
            ]
        case .host(let host):
            return [
                "host", host.alias, GeneralConfig.current.displayName(of: host), state(at: index)?.rawValue ?? "",
            ]
        }
    }

    override func applyFilter(query: String) {
        let groups = Self.groups(
            open: open, elsewhere: elsewhere, entries: entries, hosts: hosts, listings: listings,
            configured: configuredPaths, owners: worktreeOwners)
        rows = Self.list(groups, query: newWorkspaceName(query))
    }

    private static func score(_ worktree: Worktree, _ query: String) -> Int? {
        var candidates = [worktree.path.lastPathComponent]
        candidates.append(worktree.branch ?? worktree.head)
        return candidates.compactMap { FuzzyMatch.score(query, $0) }.max()
    }

    override func returnAction(at index: Int) -> String? {
        switch rows[index] {
        case .newWorkspace: return "New Workspace"
        case .add: return "Add Workspace"
        case .host(let host): return host == currentHost || hostOpenState(host) != .closed ? "Switch" : "Open"
        default: break
        }
        return openState(row: rows[index]) == .closed ? "Open" : "Switch"
    }

    override func shortcutHints(at index: Int) -> [HintFooter.Hint] {
        let keymap = GeneralConfig.current.keymap
        var hints: [HintFooter.Hint] = []
        if let chord = Chord.displayed(.newWorkspace, in: keymap) {
            hints.append(HintFooter.Hint(keys: chord.displayGlyph, label: Self.newHintLabel))
        }
        if createTarget != nil, let chord = Chord.displayed(.createWorktree, in: keymap) {
            hints.append(HintFooter.Hint(keys: chord.displayGlyph, label: "New Worktree"))
        }
        if let chord = Chord.displayed(.removeWorktree, in: keymap) {
            if selectedWorktree != nil {
                hints.append(HintFooter.Hint(keys: chord.displayGlyph, label: "Remove Worktree"))
            }
            if selectedRemovedWorkspace != nil {
                hints.append(HintFooter.Hint(keys: chord.displayGlyph, label: "Close Workspace"))
            }
        }
        return hints
    }

    struct CreateTarget: Equatable {
        let workspace: Workspace
        let repo: URL
    }

    var createTarget: CreateTarget? {
        guard rows.indices.contains(selected) else { return nil }
        switch rows[selected] {
        case .newWorkspace, .add, .host: return nil
        case .closedParent(_, let entry): return entry.map { CreateTarget(workspace: $0, repo: $0.path) }
        case .open(let row), .elsewhere(let row):
            if row.isWorktree {
                guard let found = listedWorktree(at: row.folder) else { return nil }
                return CreateTarget(workspace: found.parent, repo: found.worktree.path)
            }
            guard let entry = entries.first(where: { $0.path.standardizedFileURL == row.folder.standardizedFileURL })
            else { return nil }
            return CreateTarget(workspace: entry, repo: entry.path)
        case .workspace(let workspace):
            return CreateTarget(workspace: workspace, repo: workspace.path)
        case .worktree(let worktree, let parent):
            return CreateTarget(workspace: parent, repo: worktree.path)
        }
    }

    var selectedWorktree: (worktree: Worktree, parent: Workspace)? {
        guard rows.indices.contains(selected) else { return nil }
        switch rows[selected] {
        case .worktree(let worktree, let parent): return (worktree, parent)
        case .open(let row), .elsewhere(let row):
            guard row.isWorktree, row.removedWorktreeName == nil else { return nil }
            return listedWorktree(at: row.folder)
        default: return nil
        }
    }

    var selectedRemovedWorkspace: RunningWorkspace? {
        guard rows.indices.contains(selected) else { return nil }
        switch rows[selected] {
        case .open(let row), .elsewhere(let row): return row.removedWorktreeName == nil ? nil : row
        default: return nil
        }
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .newWorkspace: onNewWorkspace(newWorkspaceName)
        case .add: onAddWorkspace()
        case .closedParent(_, let entry): if let entry { onChoose(entry, nil) }
        case .open(let row):
            guard let id = row.id else { return }
            onSwitch(id)
        case .elsewhere(let row):
            guard let id = row.id else { return }
            if onReveal(row.window, id) { return }
            if let entry = entries.first(where: {
                $0.path.standardizedFileURL == row.folder.standardizedFileURL
            }) {
                onChoose(entry, nil)
                return
            }
            Log.info("workspace reveal found no window holding it", category: .workspace)
            elsewhere.removeAll { $0.window == row.window && $0.id == row.id }
            rebuild()
        case .workspace(let workspace): onChoose(workspace, nil)
        case .host(let host): onActivateHost(host)
        case .worktree(let worktree, let parent):
            onChoose(
                Self.workspace(for: worktree, parent: parent, repoRoot: GitRepoStatus.repoRoot(parent.path)),
                WorktreeOrigin(parent: parent, worktree: worktree))
        }
    }

    /// A worktree is cut at the repo root, so a parent pointing into the repo opens at its own folder inside it.
    static func workspace(for worktree: Worktree, parent: Workspace, repoRoot: URL?) -> Workspace {
        Workspace(
            title: "\(parent.title): \(worktree.name)",
            path: GitRepo.mirrored(parent.path, from: repoRoot, into: worktree.path)
                ?? worktree.path.standardizedFileURL,
            tabs: parent.tabs, focus: parent.focus, env: parent.env, carry: parent.carry)
    }

    final class ActionRowView: SelectableRowView {
        enum Emphasis {
            // New Workspace holds the default selection, so it reads as a row rather than a footnote.
            case listed
            case quiet

            var ink: ChromeTheme.InkLevel { self == .listed ? .normal : .muted }
        }

        init(icon: ProcessIcon, title: String, shortcut: String?, emphasis: Emphasis = .quiet) {
            super.init(
                Content(
                    title: title, leading: .process(icon), trailing: shortcut.map { .keycap($0) },
                    ink: emphasis.ink))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    final class HostRowView: SelectableRowView {
        let host: SSHHostID
        let state: State?

        init(host: SSHHostID, status: SSHHostStatus, state: State?) {
            self.host = host
            self.state = state
            super.init(
                Content(
                    title: GeneralConfig.current.displayName(of: host), titleSuffix: state?.rawValue,
                    leading: .process(.host)))
            setStatus(status)
        }

        func setStatus(_ status: SSHHostStatus) {
            detail = status.word
            setAccessibilityValue([status.word, state?.rawValue].compactMap { $0 }.joined(separator: ", "))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    final class RemovingRowView: SelectableRowView {
        let name: String

        init(worktree: Worktree) {
            name = worktree.name
            super.init(Content(title: "Removing \(name)…", leading: .spinner, ink: .faint, nesting: .indented))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    /// The branch fills in later: reading `HEAD` is filesystem I/O and can't run on the main thread.
    final class RowView: SelectableRowView {
        enum Style {
            case workspace
            case openChild
            case closedChild
            case ghost

            var ink: ChromeTheme.InkLevel {
                switch self {
                case .workspace, .openChild: return .normal
                case .closedChild: return .muted
                case .ghost: return .faint
                }
            }

            var isChild: Bool { self == .openChild || self == .closedChild }

            var icon: ProcessIcon { isChild ? .workspaceWorktree : .workspace }
        }

        let workspace: Workspace?
        let worktree: Worktree?
        let running: RunningWorkspace?
        let style: Style
        let label: String
        let state: State?
        private let statusPath: URL?
        private let churnLabel = NSTextField(labelWithString: "")

        static func churnText(_ churn: GitChurn) -> NSAttributedString {
            let chrome = Theme.current.chrome
            func token(_ text: String, _ tone: ConfirmCardList.Tone) -> NSAttributedString {
                NSAttributedString(
                    string: text,
                    attributes: [.foregroundColor: ConfirmCardList.color(tone, chrome), .font: StatusTokens.font])
            }
            var groups: [NSAttributedString] = []
            if churn.ahead > 0 { groups.append(token("⇡\(churn.ahead)", .role(\.info))) }
            if churn.behind > 0 { groups.append(token("⇣\(churn.behind)", .role(\.destructive))) }
            groups += GitStatusCategory.tokens(counting: churn.count(of:)).map {
                token($0.text, $0.category.tone)
            }
            return StatusTokens.joined(groups)
        }

        static let typeRail = "Worktree"

        convenience init(workspace: Workspace) {
            self.init(
                workspace: workspace, worktree: nil, running: nil, label: workspace.title,
                statusPath: workspace.path, style: .workspace, state: nil)
        }

        convenience init(worktree: Worktree, parent: Workspace, state: State? = nil) {
            self.init(
                workspace: parent, worktree: worktree, running: nil, label: Self.typeRail,
                statusPath: worktree.path, style: state == nil ? .closedChild : .openChild, state: state)
        }

        convenience init(open: RunningWorkspace, state: State?) {
            self.init(
                workspace: nil, worktree: nil, running: open,
                label: open.isWorktree ? open.pinnedName ?? Self.typeRail : open.name, statusPath: open.folder,
                style: open.isWorktree ? .openChild : .workspace, state: state)
        }

        convenience init(ghost: RunningWorkspace) {
            self.init(
                workspace: nil, worktree: nil, running: ghost, label: ghost.name, statusPath: nil,
                style: .ghost, state: nil)
        }

        private init(
            workspace: Workspace?, worktree: Worktree?, running: RunningWorkspace?, label: String,
            statusPath: URL?, style: Style, state: State?
        ) {
            self.workspace = workspace
            self.worktree = worktree
            self.running = running
            self.style = style
            self.label = label
            self.state = state
            self.statusPath = statusPath
            super.init(
                Content(
                    title: label, titleSuffix: state?.rawValue, leading: .process(style.icon), ink: style.ink,
                    nesting: style.isChild ? .indented : .none))

            churnLabel.alignment = .right
            churnLabel.lineBreakMode = .byClipping
            churnLabel.maximumNumberOfLines = 1
            churnLabel.setContentHuggingPriority(.required, for: .horizontal)
            churnLabel.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)

            accessories = [churnLabel, detailLabel]
            applyGitStatus()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        static func headDescription(_ head: String, _ worktree: Worktree?) -> String {
            guard let worktree else { return "on branch \(head)" }
            return worktree.branch == nil
                ? "worktree with a detached head at \(head)" : "worktree on branch \(head)"
        }

        func applyGitStatus() {
            guard let statusPath else { return }
            if let removed = running?.removedWorktreeName {
                return applyRemoved(removed)
            }
            let head =
                worktree.map(\.name)
                ?? GitRepoStatus.branch(statusPath)
            detail = head ?? ""
            detailLabel.setAccessibilityLabel(head.map { Self.headDescription($0, worktree) })
            announce()

            let churn = GitRepoStatus.churn(statusPath) ?? GitChurn()
            churnLabel.attributedStringValue = Self.churnText(churn)
        }

        private func applyRemoved(_ name: String) {
            detail = "\(name) \(WorktreeOrigin.removedDetail)"
            detailLabel.setAccessibilityLabel("worktree \(name), \(WorktreeOrigin.removedDetail)")
            announce()
            churnLabel.attributedStringValue = NSAttributedString()
        }

        private func announce() {
            let parts = [detailLabel.accessibilityLabel(), state?.rawValue].compactMap { $0 }
            setAccessibilityValue(parts.isEmpty ? nil : parts.joined(separator: ", "))
        }
    }
}
