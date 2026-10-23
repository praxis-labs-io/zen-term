import AppKit

// Clips a slide's travel to the view's bounds for the length of the animation.
enum SlideClip {
    static func apply(to view: NSView) {
        view.wantsLayer = true
        let mask = CALayer()
        mask.backgroundColor = CGColor(gray: 1, alpha: 1)
        mask.frame = view.bounds
        view.layer?.mask = mask
    }

    static func remove(from view: NSView) { view.layer?.mask = nil }
}
