import AppKit

enum KeyboardFocus {
    enum Key: Equatable {
        case up
        case down
        case left
        case right
        case tab(shift: Bool)
        case activate
        case delete
        case escape
    }

    static func key(for event: NSEvent) -> Key? {
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 48: return .tab(shift: event.modifierFlags.contains(.shift))
        case 36, 76, 49: return .activate
        case 51, 117: return .delete
        case 53: return .escape
        default: return nil
        }
    }

    static func isReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76) && isUnmodified(event)
    }

    static func isUnmodified(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(reservableModifiers).isEmpty
    }

    /// Not `deviceIndependentFlagsMask`: AppKit tags every arrow with `.function` and `.numericPad`.
    private static let reservableModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    static func isOptionOnly(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(reservableModifiers) == .option
    }

    static func isFocused(_ view: NSView, in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSTextField {
            return field === view
        }
        return responder === view
    }

    static func step(from: Int?, delta: Int, count: Int, wrap: Bool = false) -> Int? {
        guard count > 0 else { return nil }
        guard let from else { return delta > 0 ? 0 : count - 1 }
        let next = from + delta
        if (0..<count).contains(next) { return next }
        guard wrap else { return nil }
        return ((next % count) + count) % count
    }

    enum Travel { case up, down, unknown }

    static func reveal(_ stop: NSView, among stops: [NSView], travelling: Travel = .unknown) {
        guard let scroll = stop.enclosingScrollView, let document = scroll.documentView else { return }
        document.layoutSubtreeIfNeeded()
        let viewport = scroll.contentView.bounds.height
        guard viewport > 0 else { return }
        let frame = stop.convert(stop.bounds, to: document)
        let padded = frame.insetBy(dx: 0, dy: -12)
        let previousBottom =
            stops
            .map { $0.convert($0.bounds, to: document).maxY }
            .filter { $0 <= frame.minY }
            .max() ?? document.bounds.minY

        let margin = min(84, viewport / 3)
        let revealTop = min(previousBottom, padded.minY)
        var top = scroll.contentView.bounds.minY
        if travelling != .up, padded.maxY + margin > top + viewport {
            top = padded.maxY + margin - viewport
        }
        if travelling != .down, revealTop - margin < top { top = revealTop - margin }
        if padded.maxY > top + viewport { top = padded.maxY - viewport }
        if padded.minY < top { top = padded.minY }
        let clamped = min(max(0, top), max(0, document.frame.height - viewport))
        let scale = scroll.window?.backingScaleFactor ?? 2
        scroll.contentView.scroll(
            to: NSPoint(x: scroll.contentView.bounds.minX, y: (clamped * scale).rounded() / scale))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
