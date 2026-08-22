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
        // Fix the resize floor ourselves. With no explicit minimum, AppKit derives the window's
        // size range from the content view's constraint-based fitting size — and every modal overlay
        // (palette, repo picker) pins edge-to-edge to the content and sizes its card
        // *proportionally* to the container, so its constraints are satisfiable down to near-zero.
        // Mounting one then lets that derived minimum collapse, and the window gets clamped small
        // until the modal is removed. An explicit floor decouples the window from transient content
        // constraints, so no present overlay (or future one) can shrink it.
        contentMinSize = NSSize(width: 480, height: 320)
        tabbingMode = .disallowed  // no native macOS tabs / window merging (multi-window + yabai)
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
        // The traffic lights show by default; `window-chrome = false` hides them for the fully
        // chromeless top (close/minimize via ⌘W / ⌘M and the menu, drag by background). Kept as a
        // runtime setter so the Settings toggle applies live. titleVisibility / transparency /
        // fullSizeContentView stay put either way — we want buttons, not an opaque title bar.
        setWindowChromeVisible(GeneralConfig.current.windowChrome)
    }

    /// Show or hide the three standard macOS window buttons. The header space that clears them is
    /// the tile region's top inset (`ChromeMetrics.topInset`), re-applied on the same config change.
    func setWindowChromeVisible(_ shown: Bool) {
        standardWindowButton(.closeButton)?.isHidden = !shown
        standardWindowButton(.miniaturizeButton)?.isHidden = !shown
        standardWindowButton(.zoomButton)?.isHidden = !shown
    }
}
