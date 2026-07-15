import AppKit

/// An `NSClipView` with a top-left origin, so a scroll view's document lays out and scrolls
/// top-down (a vertical list starts at the top and scrolls down) instead of AppKit's default
/// bottom-gravity. Used for the Settings nav list.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
