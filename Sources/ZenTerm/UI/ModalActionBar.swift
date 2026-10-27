import AppKit

final class ModalActionBar: NSStackView {
    init(leading: [NSView] = [], trailing: [AppButton]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .horizontal
        alignment = .centerY
        spacing = ChromeMetrics.Spacing.s8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in leading + [spacer] + trailing { addArrangedSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
