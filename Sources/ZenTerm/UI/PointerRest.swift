import AppKit

// Rows scrolling or re-laying out under a still pointer get hover too, and that is not the person pointing.
enum PointerRest {
    static var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private static var restingAt: NSPoint?

    static func keyboardDidTakeOver() { restingAt = pointerLocation() }

    static func claimPointerMove() -> Bool {
        guard let restingAt else { return true }
        guard pointerLocation() != restingAt else { return false }
        Self.restingAt = nil
        return true
    }

    static func resetForTesting() {
        restingAt = nil
        pointerLocation = { NSEvent.mouseLocation }
    }
}
