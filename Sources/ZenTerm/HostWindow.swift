import AppKit

/// Minimal-chrome window: a titled window with a hidden/transparent title bar and
/// full-size content view. NOT `.borderless` — we keep free key-window, drag, and
/// resize behavior. This is the low-effort path to minimal chrome.
final class HostWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = NSColor(srgbRed: 0x23 / 255.0, green: 0x21 / 255.0, blue: 0x36 / 255.0, alpha: 1)
        // Traffic lights stay visible for PoC usability. To go fully chromeless,
        // hide each: standardWindowButton(.closeButton)?.isHidden = true (etc).
    }
}
