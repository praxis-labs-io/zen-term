import AppKit

final class PaletteSectionHeader: NSView, PaletteRowView {
    static let height: CGFloat = ChromeMetrics.Height.sm

    var isSelected = false
    var onActivate: (() -> Void)?

    let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)

        let label = SectionCaption(title)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ChromeMetrics.Spacing.s4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
