import AppKit

// The base for a chrome control that is a plain view: hover, keyboard focus, eased fill and focus ring through `ControlState`.
class ControlView: NSView, HoverSuppressing {
    private lazy var state = ControlState(
        host: self,
        hoverChanged: { [unowned self] in hoverDidChange() },
        focusChanged: { [unowned self] in focusDidChange() })

    var isHovered: Bool { state.isHovered }
    var hasKeyboardFocus: Bool { state.hasKeyboardFocus }
    var isHoverSuppressed: Bool { state.isHoverSuppressed }
    var showsHover: Bool { state.showsHover }

    func hoverDidChange() {}
    func focusDidChange() {}

    func setHovered(_ on: Bool) { state.setHovered(on) }
    func setKeyboardFocus(_ on: Bool) { state.setKeyboardFocus(on) }
    func refreshHover() { state.refreshHover() }

    func setHoverSuppressed(_ suppressed: Bool) { state.setHoverSuppressed(suppressed) }
    func hoverCoverDidChange() { state.hoverCoverDidChange() }
    func easeFill(_ color: NSColor, from start: CGColor? = nil) { state.easeFill(color, from: start) }
    func snapFill(_ color: NSColor) { state.snapFill(color) }
    func showFocusRing(_ shown: Bool) { state.showFocusRing(shown) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        state.updateTrackingArea()
    }

    override func mouseEntered(with event: NSEvent) { state.pointerEntered() }
    override func mouseExited(with event: NSEvent) { state.pointerExited() }

    override func viewDidHide() {
        super.viewDidHide()
        state.clearHover()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { state.setKeyboardFocus(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { state.setKeyboardFocus(false) }
        return ok
    }
}
