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
        tabbingMode = .disallowed   // no native macOS tabs / window merging (multi-window + yabai)
        // The WindowController owns this window with a strong reference. Without this,
        // AppKit ALSO releases the window on close (default true), underflowing the
        // retain count and crashing in the close-time CoreAnimation commit.
        isReleasedWhenClosed = false
        // Transparent window: the tinted blur backdrop (a behind-window NSVisualEffectView
        // installed by WindowController) shows through every gap the opaque terminal
        // surfaces don't cover — the pane gutters, the window inset, and the rounded pane
        // corners. `isOpaque = false` + a clear background is what lets the vibrancy read
        // through; the window keeps its titled shadow (no hard app border).
        isOpaque = false
        backgroundColor = .clear
        // Fully chromeless top: hide the traffic lights. Close/minimize/zoom via ⌘W /
        // ⌘M / ⌘F-equivs and the menu; the window drags by its background.
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }
}
