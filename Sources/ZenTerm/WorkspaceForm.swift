import Foundation

// The tabs, launch focus and name state the workspace form edits, apart from the views that draw them.
struct WorkspaceForm: Equatable {
    struct Removal: Equatable {
        let tab: Workspace.Tab
        let index: Int
        let focus: Workspace.LaunchFocus
        let selected: Int
    }

    private(set) var tabs: [Workspace.Tab]
    private(set) var launchFocus: Workspace.LaunchFocus
    private(set) var selected = 0
    private(set) var lastRemoval: Removal?
    private(set) var nameFollowsFolder: Bool

    static let shellLabel = "shell"

    init(editing workspace: Workspace?) {
        tabs = workspace?.tabs ?? [Workspace.Tab()]
        launchFocus = workspace?.focus ?? .start
        nameFollowsFolder = workspace == nil
        launchFocus = Self.repaired(launchFocus, in: tabs)
    }

    var isSoleTab: Bool { tabs.count == 1 }

    var selectedTab: Workspace.Tab { tabs[selected] }

    func chipLabel(at index: Int) -> String {
        let tab = tabs[index]
        return tab.name ?? tab.main ?? Self.shellLabel
    }

    func isOpen(_ region: Workspace.Region, inTab index: Int) -> Bool {
        region == .main || tabs[index].command(in: region) != nil
    }

    mutating func select(_ index: Int) {
        selected = min(max(index, 0), tabs.count - 1)
    }

    mutating func addTab() {
        tabs.append(Workspace.Tab())
        selected = tabs.count - 1
        lastRemoval = nil
    }

    mutating func renameTab(at index: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        tabs[index].name = trimmed.isEmpty ? nil : trimmed
        lastRemoval = nil
    }

    mutating func removeTab(at index: Int) -> String? {
        guard tabs.count > 1, tabs.indices.contains(index) else { return nil }
        let removedLabel = chipLabel(at: index)
        lastRemoval = Removal(tab: tabs[index], index: index, focus: launchFocus, selected: selected)
        tabs.remove(at: index)
        if selected > index || selected == tabs.count { selected -= 1 }
        if launchFocus.tab == index {
            launchFocus = .start
            return "Removed \(removedLabel). \(chipLabel(at: 0))'s main pane opens focused."
        }
        if launchFocus.tab > index { launchFocus.tab -= 1 }
        return "Removed \(removedLabel)."
    }

    mutating func undoRemoval() {
        guard let removal = lastRemoval else { return }
        tabs.insert(removal.tab, at: removal.index)
        launchFocus = removal.focus
        selected = removal.selected
        lastRemoval = nil
    }

    mutating func moveTab(at index: Int, to target: Int) {
        let destination = min(max(target, 0), tabs.count - 1)
        guard tabs.indices.contains(index), destination != index else { return }
        tabs.insert(tabs.remove(at: index), at: destination)
        func moved(_ k: Int) -> Int {
            if k == index { return destination }
            if index < k, k <= destination { return k - 1 }
            if destination <= k, k < index { return k + 1 }
            return k
        }
        launchFocus.tab = moved(launchFocus.tab)
        selected = moved(selected)
        lastRemoval = nil
    }

    mutating func setCommand(_ text: String, in region: Workspace.Region, ofTab index: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let command = trimmed.isEmpty ? nil : trimmed
        switch region {
        case .main: tabs[index].main = command
        case .right: tabs[index].right = command
        case .bottom: tabs[index].bottom = command
        }
    }

    @discardableResult
    mutating func setLaunchFocus(_ region: Workspace.Region, inTab index: Int) -> Bool {
        guard tabs.indices.contains(index), isOpen(region, inTab: index) else { return false }
        let focus = Workspace.LaunchFocus(tab: index, region: region)
        if focus != launchFocus { lastRemoval = nil }
        launchFocus = focus
        return true
    }

    mutating func repairLaunchFocus() -> String? {
        let repaired = Self.repaired(launchFocus, in: tabs)
        guard repaired != launchFocus else { return nil }
        let closed = Self.label(for: launchFocus.region)
        launchFocus = repaired
        lastRemoval = nil
        return "The \(closed.lowercased()) is closed. \(chipLabel(at: repaired.tab))'s main pane opens focused."
    }

    func build() -> (tabs: [Workspace.Tab], focus: Workspace.LaunchFocus) {
        (tabs, Self.repaired(launchFocus, in: tabs))
    }

    mutating func nameEdited(_ text: String) {
        nameFollowsFolder = text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func folderName(_ folderText: String) -> String {
        let trimmed = folderText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let name = URL(fileURLWithPath: PathDisplay.expandingHome(trimmed)).lastPathComponent
        return name == "/" ? "" : name
    }

    static func label(for region: Workspace.Region) -> String {
        switch region {
        case .main: return "Main pane"
        case .right: return "Right drawer"
        case .bottom: return "Bottom drawer"
        }
    }

    private static func repaired(_ focus: Workspace.LaunchFocus, in tabs: [Workspace.Tab]) -> Workspace.LaunchFocus {
        let tab = min(max(focus.tab, 0), tabs.count - 1)
        guard focus.region == .main || tabs[tab].command(in: focus.region) != nil else {
            return Workspace.LaunchFocus(tab: tab, region: .main)
        }
        return Workspace.LaunchFocus(tab: tab, region: focus.region)
    }
}
