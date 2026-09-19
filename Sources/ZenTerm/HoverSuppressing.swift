import AppKit

/// A view under an overlay that covers it without taking its tracking area's events, so it must be told to stop hovering.
@MainActor
protocol HoverSuppressing: NSView {
    func setHoverSuppressed(_ suppressed: Bool)
    /// Re-reads the pointer. Rows that move under a still cursor never get `mouseExited`, so hover sticks on several.
    func refreshHover()
}

extension NSView {
    var pointerIsInside: Bool {
        guard let window, window.isKeyWindow else { return false }
        return convert(bounds, to: nil).contains(window.mouseLocationOutsideOfEventStream)
    }
}
