import AppKit
import TerminalKit

/// The band scroll mode draws on the row it is sitting on (ZEN-330).
///
/// libghostty has no copy mode and no notion of a cursor outside the shell's own, so the chrome
/// draws this itself: a translucent fill across the row, over the terminal's content and inside
/// the pane's rounded clip.
///
/// It reads its geometry from `TerminalCellMetrics` at draw time rather than caching it, because
/// the row height moves with the font size and the row count moves with every resize. Caching it
/// is how the band ends up a row out of true after a ⌘+.
final class ScrollCursorView: NSView {
    /// Where the grid is, asked for on every layout pass. A closure rather than a stored value so
    /// a resize or a font step is reflected without anything having to remember to push.
    var metrics: (() -> TerminalCellMetrics?)?

    /// The viewport row the band sits on, 0 at the top.
    var row: Int = 0 {
        didSet { if oldValue != row { needsDisplay = true } }
    }

    /// Top-down coordinates, matching how a terminal counts its rows. Without this every row
    /// index would have to be flipped against a row count that changes on resize.
    override var isFlipped: Bool { true }

    /// The pane behind this is a live terminal: clicks, drags and text selection all have to
    /// reach it, so the band is paint and nothing else.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        needsDisplay = true  // the row's frame is derived from metrics that just moved
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let metrics = metrics?(), metrics.rows > 0 else { return }
        Theme.current.chrome.accent.nsColor.withAlphaComponent(Self.fillAlpha).setFill()
        bounds.intersection(metrics.rowFrame(row, width: bounds.width)).fill()
    }

    /// Low enough that the text under the band stays readable, high enough to find at a glance on
    /// a busy screen. The band marks a row; it does not select it, so it must not read as
    /// strongly as a selection would.
    private static let fillAlpha: CGFloat = 0.16
}
