import AppKit

// A bounds mask would clip the pane focus halo for the length of a slide.
enum SlideClip {
    // Covers the focus glow (shadow radius 6 plus the pane border), far short of any slide travel.
    static let margin: CGFloat = 10

    static func apply(to view: NSView) {
        view.wantsLayer = true
        let mask = CALayer()
        mask.backgroundColor = CGColor(gray: 1, alpha: 1)
        mask.frame = view.bounds.insetBy(dx: -margin, dy: -margin)
        view.layer?.mask = mask
    }

    static func remove(from view: NSView) { view.layer?.mask = nil }
}
