import AppKit

// The hover, keyboard focus, eased fill and focus ring every chrome control shares, for `ControlView` and `AppButton`.
@MainActor
final class ControlState {
    private unowned let host: NSView
    private let hoverChanged: () -> Void
    private let focusChanged: () -> Void
    private var trackingArea: NSTrackingArea?
    // Hover set by code (a gallery sample, a strip's own pointer sweep) is not the pointer's to clear.
    private var hoverFollowsPointer = false
    private(set) var isHovered = false
    private(set) var hasKeyboardFocus = false

    init(host: NSView, hoverChanged: @escaping () -> Void, focusChanged: @escaping () -> Void) {
        self.host = host
        self.hoverChanged = hoverChanged
        self.focusChanged = focusChanged
    }

    // A control that moves out from under a still pointer never gets `mouseExited`.
    func updateTrackingArea() {
        if let trackingArea { host.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: host.bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: host)
        host.addTrackingArea(area)
        trackingArea = area
        if hoverFollowsPointer, host.window?.isKeyWindow == true, !host.pointerIsInside { setHovered(false) }
    }

    func pointerEntered() {
        hoverFollowsPointer = true
        setHovered(true)
    }

    func pointerExited() { setHovered(false) }

    func refreshHover() {
        hoverFollowsPointer = true
        setHovered(host.pointerIsInside)
    }

    // A hidden control never gets `mouseExited`, so it would come back hovered.
    func clearHover() { setHovered(false) }

    func setHovered(_ on: Bool) {
        if !on { hoverFollowsPointer = false }
        guard on != isHovered else { return }
        isHovered = on
        hoverChanged()
    }

    func setKeyboardFocus(_ on: Bool) {
        guard on != hasKeyboardFocus else { return }
        hasKeyboardFocus = on
        focusChanged()
    }

    func easeFill(_ color: NSColor) {
        guard let layer = host.layer else { return }
        let target = color.cgColor
        guard layer.backgroundColor != target else { return }
        Motion.ease(layer, keyPath: "backgroundColor", to: target)
    }

    func showFocusRing(_ shown: Bool) {
        host.layer?.borderWidth = ChromeMetrics.Border.width
        host.layer?.borderColor = (shown ? Theme.current.chrome.focusRing : .clear).cgColor
    }
}
