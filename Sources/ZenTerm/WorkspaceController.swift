import Foundation
import TabKit
import TerminalKit

/// One workspace's tabs, their controllers and their titles. It has no view: the window mounts a tab's own.
@MainActor
final class WorkspaceController {
    let id: WorkspaceID
    let isConfigured: Bool
    var name: String
    let folder: URL

    private var tabs: TabList
    private var controllerByTab: [TabID: TabController] = [:]
    private var titleByTab: [TabID: String] = [:]

    init(id: WorkspaceID, isConfigured: Bool, name: String, folder: URL, firstTab: TabID) {
        self.id = id
        self.isConfigured = isConfigured
        self.name = name
        self.folder = folder
        tabs = TabList(first: firstTab)
    }

    var tabIDs: [TabID] { tabs.order }

    /// Nil once `close` has taken the last tab, because `TabList.activeID` traps on an empty list.
    var activeID: TabID? { tabs.order.isEmpty ? nil : tabs.activeID }

    var activeController: TabController? { activeID.flatMap { controllerByTab[$0] } }

    var controllers: [TabController] { Array(controllerByTab.values) }

    var allSurfaces: [TerminalSurface] { controllerByTab.values.flatMap { $0.allSurfaces } }

    func controller(_ id: TabID) -> TabController? { controllerByTab[id] }

    func title(_ id: TabID) -> String? { titleByTab[id] }

    func setTitle(_ title: String?, for id: TabID) { titleByTab[id] = title }

    /// Appends `id` and makes it active. Its controller arrives separately, once the caller has wired it.
    func add(_ id: TabID) { tabs.add(id) }

    /// Files the controller and seeds its title. A replaced tab keeps its id, so this also overwrites.
    func setController(_ controller: TabController, for id: TabID) {
        controllerByTab[id] = controller
        titleByTab[id] = controller.title
    }

    func select(_ id: TabID) { tabs.select(id) }

    @discardableResult
    func move(_ id: TabID, by delta: Int) -> Bool { tabs.move(id, by: delta) }

    /// Returns false when that was the last tab, leaving the workspace empty for the caller to close.
    @discardableResult
    func close(_ id: TabID) -> Bool {
        let survived = tabs.close(id)
        controllerByTab[id] = nil
        titleByTab[id] = nil
        return survived
    }

    func shutdown() {
        for controller in controllerByTab.values { controller.shutdown() }
        controllerByTab.removeAll()
        titleByTab.removeAll()
    }
}
