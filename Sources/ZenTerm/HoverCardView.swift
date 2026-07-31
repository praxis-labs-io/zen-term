import AppKit

/// The transient hover-card idiom shared by `ChromeTooltip` and `LinkPreviewView`: the chrome's
/// card look (themed background + hairline edge + a soft elevation shadow), pointer
/// transparency, and the placement and window-level dismissal every such card needs. One home so
/// the cards cannot drift apart.
class HoverCardView: ShadowCardView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Framed directly by presenters (not Auto Layout), so leave the default
        // translatesAutoresizingMaskIntoConstraints = true.
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
        // A lighter elevation than FloatShadow's full card shadow — a hover card floats just
        // above its trigger, not over the whole canvas. Black is a theme-independent shadow (the
        // documented FloatShadow exception), not a chrome color. Via `NSView.shadow`, not
        // `layer.shadow*`, so AppKit's view→layer re-sync can't zero it (see
        // FloatShadow.applyShadow).
        layer?.masksToBounds = false
        let elevation = NSShadow()
        elevation.shadowColor = NSColor.black.withAlphaComponent(0.35)
        elevation.shadowBlurRadius = 8
        elevation.shadowOffset = NSSize(width: 0, height: -3)
        shadow = elevation
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Never intercept the pointer — a hover card is a passive label floating above its trigger.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A hover card's one-line label: 11pt medium in foreground ink.
    static func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = Theme.current.chrome.ink(alpha: 0.9)
        return label
    }

    /// Where a card of `size` sits relative to `anchor` (a rect in `content` coordinates; a
    /// pointer anchors as a zero-size rect): centered on the anchor, `gap` above it, clamped
    /// inside `content` by `margin`, flipped below when the top edge would clip. The width caps
    /// to what `content` can hold FIRST — otherwise the x-clamp's bounds cross in a window
    /// narrower than the card and the card runs off the trailing edge, clipping exactly the tail
    /// a middle-truncated label preserves.
    static func placementFrame(
        size: NSSize, anchor: NSRect, in content: NSView, gap: CGFloat, margin: CGFloat = 8
    ) -> NSRect {
        let width = min(size.width, max(0, content.bounds.width - 2 * margin))
        var x = anchor.midX - width / 2
        x = max(margin, min(x, content.bounds.width - width - margin))

        // The "up" direction and the clip test depend on the content view's flippedness.
        let y: CGFloat
        if content.isFlipped {
            let above = anchor.minY - gap - size.height
            y = above < margin ? anchor.maxY + gap : above
        } else {
            let above = anchor.maxY + gap
            y =
                above + size.height > content.bounds.height - margin
                ? anchor.minY - gap - size.height : above
        }
        return NSRect(x: x, y: y, width: width, height: size.height)
    }

    /// The window-level dismissals every hover card owes: the window losing key, the window
    /// closing, and the app deactivating. Returns the observers for the caller to hold and
    /// remove on its own teardown.
    static func windowDismissObservers(
        in window: NSWindow, onDismiss: @escaping () -> Void
    ) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        var observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map {
            center.addObserver(forName: $0, object: window, queue: .main) { _ in onDismiss() }
        }
        observers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { _ in onDismiss() })
        return observers
    }
}
