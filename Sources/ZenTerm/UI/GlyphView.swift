import AppKit

// `NSImageView` takes alignment insets from SF Symbol baseline metadata, which hangs symbols off-centre beside brand marks.
final class GlyphView: NSImageView {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}
