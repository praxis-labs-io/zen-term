import AppKit
import AppLog

final class UpdateCardView: ShadowCardView {
    enum State: Equatable {
        case available(version: String, current: String, notes: [String], notesURL: URL?)
        case downloading(fraction: Double?)
        case ready(version: String)

        var logLabel: String {
            switch self {
            case .available(let version, _, _, _): return "available \(version)"
            case .downloading(let fraction):
                return "downloading \(fraction.map { "\(Int($0 * 100))%" } ?? "…")"
            case .ready(let version): return "ready \(version)"
            }
        }
    }

    struct Actions {
        var install: () -> Void = {}
        var later: () -> Void = {}
        var skip: () -> Void = {}
        var relaunch: () -> Void = {}
        var whatsNew: (URL) -> Void = { _ in }
    }

    static let width: CGFloat = 360
    private static let inset: CGFloat = 12
    private static let badgeSize: CGFloat = 28
    private static let rootSpacing: CGFloat = 12

    // Exposed so the notes are measured against the real wrap budget (`UpdateCardTests`).
    static let notesMaxWidth: CGFloat = width - inset * 2 - badgeSize - rootSpacing
    static let notesFont: NSFont = .systemFont(ofSize: 12)

    private var state: State
    private var actions: Actions

    private let badgeFill = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let header = NSStackView()
    // Nil while unbound, the default, so the slot never shows a glyph that does nothing.
    private var checkKeycap: KeycapView?
    private let bodyColumn = NSStackView()
    private let buttonRow = NSStackView()
    private let progressBar = UpdateProgressBar()

    init(state: State, actions: Actions) {
        self.state = state
        self.actions = actions
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        FloatShadow.applyShadow(to: self)

        badgeFill.wantsLayer = true
        badgeFill.layer?.cornerRadius = 7
        badgeFill.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BrandMark.image("origami")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        badgeFill.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(headerSpacer)
        refreshKeycap()

        bodyColumn.orientation = .vertical
        bodyColumn.alignment = .leading
        bodyColumn.spacing = 6

        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 6

        let col = NSStackView(views: [header, bodyColumn, buttonRow])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 9
        header.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        bodyColumn.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        header.heightAnchor.constraint(equalToConstant: Self.badgeSize).isActive = true

        let root = NSStackView(views: [badgeFill, col])
        root.orientation = .horizontal
        root.alignment = .top
        root.distribution = .fill
        root.spacing = Self.rootSpacing
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            badgeFill.widthAnchor.constraint(equalToConstant: Self.badgeSize),
            badgeFill.heightAnchor.constraint(equalToConstant: Self.badgeSize),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            iconView.centerXAnchor.constraint(equalTo: badgeFill.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: badgeFill.centerYAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            root.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
        ])

        applyColors()
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // A downloading tick only advances the bar: rebuilding per chunk would churn Auto Layout.
    func update(to newState: State, actions: Actions) {
        self.actions = actions
        if case .downloading = state, case .downloading(let fraction) = newState {
            state = newState
            progressBar.fraction = fraction
            return
        }
        state = newState
        render()
    }

    private func render() {
        titleLabel.stringValue = title(for: state)
        bodyColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch state {
        case .available(_, let current, let notes, let notesURL):
            addBodyLabel(current, color: Theme.current.chrome.muted.nsColor)
            if !notes.isEmpty {
                addBodyLabel(
                    notes.map { "•  \($0)" }.joined(separator: "\n"),
                    color: Theme.current.chrome.foreground.nsColor)
            }
            if let notesURL {
                let link = AppButton(title: "What's new", variant: .secondary) { [weak self] in
                    self?.actions.whatsNew(notesURL)
                }
                bodyColumn.addArrangedSubview(link)
            }
            addButton("Install", variant: .primary) { [weak self] in self?.actions.install() }
            addButton("Later", variant: .secondary) { [weak self] in self?.actions.later() }
            addButton("Skip", variant: .secondary) { [weak self] in self?.actions.skip() }

        case .downloading(let fraction):
            progressBar.fraction = fraction
            bodyColumn.addArrangedSubview(progressBar)
            progressBar.widthAnchor.constraint(equalTo: bodyColumn.widthAnchor).isActive = true

        case .ready(let version):
            addBodyLabel(
                "Relaunch to finish updating to \(version).",
                color: Theme.current.chrome.muted.nsColor)
            addButton("Relaunch", variant: .primary) { [weak self] in self?.actions.relaunch() }
            addButton("Later", variant: .secondary) { [weak self] in self?.actions.later() }
        }

        if !buttonRow.arrangedSubviews.isEmpty {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            buttonRow.addArrangedSubview(spacer)
        }

        needsLayout = true
    }

    private func title(for state: State) -> String {
        switch state {
        case .available(let version, _, _, _): return "ZenTerm \(version) is available"
        case .downloading: return "Downloading update"
        case .ready: return "Ready to install"
        }
    }

    private func addBodyLabel(_ text: String, color: NSColor) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Self.notesFont
        label.textColor = color
        label.preferredMaxLayoutWidth = Self.notesMaxWidth
        bodyColumn.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: bodyColumn.widthAnchor).isActive = true
    }

    private func addButton(_ title: String, variant: AppButton.Variant, onTap: @escaping () -> Void) {
        buttonRow.addArrangedSubview(
            AppButton(title: title, variant: variant) { [weak self] in
                Log.info("update card tap: \(title) [\(self?.state.logLabel ?? "gone")]", category: .update)
                onTap()
            })
    }

    private func applyColors() {
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderColor = FloatShadow.edge.cgColor
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        let accent = Theme.current.chrome.accent.nsColor
        badgeFill.layer?.backgroundColor =
            Theme.current.chrome.tint(Theme.current.chrome.accent, alpha: ChromeTheme.badgeTint).cgColor
        iconView.contentTintColor = accent
        progressBar.reapplyTheme()
    }

    func reapplyTheme() {
        applyColors()
        refreshKeycap()
        checkKeycap?.reapplyTheme()
        render()
    }

    private func refreshKeycap() {
        let glyph = Chord.displayed(.checkForUpdates, in: GeneralConfig.current.keymap)?.displayGlyph ?? ""
        guard glyph != checkKeycap?.shortcut else { return }
        checkKeycap.map { header.removeArrangedSubview($0) }
        checkKeycap?.removeFromSuperview()
        checkKeycap = nil
        guard !glyph.isEmpty else { return }
        let cap = KeycapView(shortcut: glyph)
        header.addArrangedSubview(cap)
        checkKeycap = cap
    }

    // Read by `hitTest` so a click on the springing-out card can't fire a stale Sparkle reply.
    private var isDismissing = false

    func beginDismissal() { isDismissing = true }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { isDismissing ? nil : super.hitTest(point) }
}
