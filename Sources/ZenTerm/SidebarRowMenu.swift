import AppKit

// A sidebar row's right-click menu: mouse picks an item, Esc or a click elsewhere closes it.
@MainActor
final class SidebarRowMenu {
    struct Item {
        let title: String
        let action: KeyInterceptor.ReservedChord
        let run: () -> Void
    }

    private struct Press: Sendable {
        let isKey: Bool
        let isEscape: Bool
        let windowNumber: Int
        let location: NSPoint

        init(_ event: NSEvent) {
            isKey = event.type == .keyDown
            isEscape = isKey && KeyboardFocus.key(for: event) == .escape
            windowNumber = event.windowNumber
            location = event.locationInWindow
        }
    }

    private static let rowHeight: CGFloat = 28

    private var popover: ListPopover?
    private(set) weak var anchor: NSView?
    private var monitor: Any?
    private var itemViews: [SidebarRowMenuItemView] = []
    private var dismissObservers: [NSObjectProtocol] = []

    var isOpen: Bool { popover?.isOpen == true }

    func open(_ items: [Item], from row: NSView) {
        close()
        guard !items.isEmpty, let window = row.window else { return }
        let popover = ListPopover(anchor: row)
        popover.onSelfClose = { [weak self] in self?.close() }
        itemViews = items.map { item in
            SidebarRowMenuItemView(item) { [weak self] in
                self?.close()
                item.run()
            }
        }
        popover.open(rows: itemViews.map { ListPopover.Row(view: $0, height: Self.rowHeight) })
        self.popover = popover
        anchor = row
        let dismissingEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: dismissingEvents) { [weak self] event in
            let press = Press(event)
            return MainActor.assumeIsolated { self?.swallows(press) ?? false } ? nil : event
        }
        dismissObservers = HoverCardView.windowDismissObservers(in: window) { [weak self] in self?.close() }
    }

    func close() {
        popover?.close()
        popover = nil
        anchor = nil
        itemViews = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        dismissObservers.forEach { NotificationCenter.default.removeObserver($0) }
        dismissObservers = []
    }

    func filter(_ event: NSEvent) -> NSEvent? { swallows(Press(event)) ? nil : event }

    private func swallows(_ press: Press) -> Bool {
        guard let popover, popover.isOpen, let window = anchor?.window, let content = window.contentView else {
            return false
        }
        if press.isKey {
            close()
            return press.isEscape
        }
        let isOnCard = popover.cardFrame.contains(content.convert(press.location, from: nil))
        if press.windowNumber == window.windowNumber, !isOnCard { close() }
        return false
    }

    var itemViewsForTesting: [SidebarRowMenuItemView] { itemViews }
}
