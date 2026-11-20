import AppKit

extension NSStackView {
    static func huggingRow(_ control: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [control, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        return row
    }
}
