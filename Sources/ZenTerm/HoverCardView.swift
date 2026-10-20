import AppKit

class HoverCardView: ShadowCardView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.surface
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = ChromeMetrics.Border.width
        layer?.borderColor = FloatShadow.edge.cgColor
        FloatShadow.apply(.overlay, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = ChromeType.font(.caption, weight: .medium)
        label.textColor = Theme.current.chrome.ink(.normal)
        return label
    }

    static func placementFrame(
        size: NSSize, anchor: NSRect, in content: NSView, gap: CGFloat, margin: CGFloat = 8
    ) -> NSRect {
        let width = min(size.width, max(0, content.bounds.width - 2 * margin))
        var x = anchor.midX - width / 2
        x = max(margin, min(x, content.bounds.width - width - margin))

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
