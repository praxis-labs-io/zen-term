import AppKit

// Cards and menus are sibling views, not windows, so the views they cover keep getting their tracking area's events.
@MainActor
protocol HoverSuppressing: NSView {
    var isHoverSuppressed: Bool { get }
    func setHoverSuppressed(_ suppressed: Bool)
    // A row that moves under a still cursor never gets `mouseExited`, so hover sticks on every row that passed under it.
    func refreshHover()
}

extension NSView {
    func hoverSuppressingDescendants(skipping skipped: NSView) -> [any HoverSuppressing] {
        guard self !== skipped else { return [] }
        let own = (self as? any HoverSuppressing).map { [$0] } ?? []
        return own + subviews.flatMap { $0.hoverSuppressingDescendants(skipping: skipped) }
    }

    var pointerIsInside: Bool {
        guard let window, window.isKeyWindow else { return false }
        return convert(bounds, to: nil).contains(window.mouseLocationOutsideOfEventStream)
    }
}
