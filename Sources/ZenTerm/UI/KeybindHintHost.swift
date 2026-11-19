import AppKit

@MainActor
final class KeybindHintHost {
    private(set) var bubble: KeybindHintBubble?
    private var backdrop: NSView?

    func show(
        over host: NSView, near anchor: NSView, configure: (KeybindHintBubble) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        hide()
        let backdrop = BackdropView(onClick: onDismiss)
        backdrop.frame = host.bounds
        backdrop.autoresizingMask = [.width, .height]
        host.addSubview(backdrop)
        self.backdrop = backdrop
        let bubble = KeybindHintBubble()
        configure(bubble)
        host.addSubview(bubble)
        self.bubble = bubble
        bubble.place(near: anchor)
    }

    func hide() {
        bubble?.removeFromSuperview()
        bubble = nil
        backdrop?.removeFromSuperview()
        backdrop = nil
    }
}
