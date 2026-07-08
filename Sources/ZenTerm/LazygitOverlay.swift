import AppKit

/// The lazygit float: a `SurfaceFloatOverlay` hosting the lazygit terminal surface in a
/// large centered card. All the float chrome and enter/exit motion live in the base; this
/// only pins down lazygit's card metrics.
final class LazygitOverlay: SurfaceFloatOverlay {
    init(content: NSView, background: NSColor, onDismiss: @escaping () -> Void) {
        super.init(
            content: content,
            background: background,
            widthFraction: 0.85,
            heightFraction: 0.78,
            contentInset: 10,
            cornerRadius: 14,
            onDismiss: onDismiss)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
