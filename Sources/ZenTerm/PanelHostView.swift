import AppKit

/// Optional top meta header for a `PanelHostView` — a small-caps label (left) and its
/// toggle keybind (right), e.g. `("BOTTOM", "⌘B")` for a drawer panel.
struct PanelMeta {
    let label: String
    let keybind: String
}

/// Hosts one terminal surface (a pane leaf today; a drawer later) inside the shared
/// rounded/bordered chrome: the iris focus halo (accent border + soft glow) and an
/// inner clip that keeps content within the corner radius. An optional top meta row
/// (label + keybind) renders above the content when `meta` is non-nil; panes pass
/// `meta: nil` and look/behave exactly as the original pane-only chrome. Clicking
/// anywhere in the panel requests focus.
final class PanelHostView: NSView {
    private let onFocusRequest: () -> Void
    private let pane = NSView()
    private let zoomButton: IconButton
    private let hideButton: IconButton?
    private static let cornerSize = NSSize(width: 22, height: 20)

    /// Invoked when the corner zoom action button is clicked — the chrome exits zoom.
    var onZoomExit: (() -> Void)?

    var isFocused: Bool = false { didSet { if oldValue != isFocused { updateHalo() } } }

    /// Whether this panel is the sole full-canvas panel (zoomed). Shows the corner
    /// unzoom button and hides the (drawer) hide button — they share the corner.
    var isZoomed: Bool = false {
        didSet {
            zoomButton.isHidden = !isZoomed
            hideButton?.isHidden = isZoomed
        }
    }

    /// Inner breathing room between the pane border and the terminal content, even on
    /// all sides so content (e.g. nvim) doesn't sit against the pane border.
    private let padding: CGFloat = 10

    init(
        content: NSView, background: NSColor, meta: PanelMeta?,
        hideButton hideSpec: (symbol: String, label: String, onHide: () -> Void)? = nil,
        onFocusRequest: @escaping () -> Void
    ) {
        self.onFocusRequest = onFocusRequest
        // Shown only while zoomed → exit-zoom (inward arrows). onClick wired post-super.
        self.zoomButton = IconButton(
            symbol: "arrow.down.right.and.arrow.up.left",
            size: Self.cornerSize, pointSize: 11,
            accessibilityLabel: "Exit zoom", onClick: {})
        self.hideButton = hideSpec.map {
            IconButton(
                symbol: $0.symbol, size: Self.cornerSize, pointSize: 11,
                accessibilityLabel: $0.label, onClick: $0.onHide)
        }
        super.init(frame: .zero)
        zoomButton.onClick = { [weak self] in self?.onZoomExit?() }
        zoomButton.isHidden = true  // only appears while zoomed

        wantsLayer = true
        pane.wantsLayer = true
        pane.layer?.cornerRadius = 12
        pane.layer?.masksToBounds = false  // glow must escape bounds; content clip is on a mask below
        pane.layer?.borderWidth = 1
        // The focus glow is a fixed iris shadow whose opacity toggles (animated in
        // updateHalo); its color/radius/offset never change, so set them once here.
        pane.layer?.shadowColor = Self.iris.cgColor
        pane.layer?.shadowRadius = 6
        pane.layer?.shadowOffset = .zero
        addSubview(pane)

        content.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSView()  // inner clip so terminal content stays inside the radius
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = background.cgColor  // fills the padding ring with the terminal bg
        clip.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(clip)
        clip.addSubview(content)

        pane.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: trailingAnchor),
            pane.topAnchor.constraint(equalTo: topAnchor),
            pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            clip.topAnchor.constraint(equalTo: pane.topAnchor),
            clip.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -padding),
            content.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -padding),
        ])

        // Both corner buttons share the top-right slot; visibility is mutually
        // exclusive (hide button when not zoomed, unzoom button when zoomed).
        pane.addSubview(zoomButton)
        var buttonCs = cornerConstraints(for: zoomButton)
        if let hideButton {
            hideButton.isHidden = false
            pane.addSubview(hideButton)
            buttonCs += cornerConstraints(for: hideButton)
        }
        NSLayoutConstraint.activate(buttonCs)

        if let meta {
            let header = Self.makeMetaHeader(meta)
            header.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(header)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 6),
                header.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -6),
                header.topAnchor.constraint(equalTo: clip.topAnchor, constant: 6),
                content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: padding),
            ])
        } else {
            content.topAnchor.constraint(equalTo: clip.topAnchor, constant: padding).isActive = true
        }

        updateHalo()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest()
        super.mouseDown(with: event)
    }

    /// Top-right corner slot (8pt inset) shared by the corner action buttons; each
    /// `IconButton` supplies its own size.
    private func cornerConstraints(for button: NSView) -> [NSLayoutConstraint] {
        [
            button.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
        ]
    }

    private static let iris = NSColor(srgbRed: 0xc4 / 255.0, green: 0xa7 / 255.0, blue: 0xe7 / 255.0, alpha: 1)
    private static let idleBorder = NSColor(white: 1, alpha: 0.08)

    private func updateHalo() {
        guard let layer = pane.layer else { return }
        // Ease from the live (presentation) value so a focus-nav crossfade falls out — the
        // losing host's glow eases down as the gaining host's eases up. Fast (haloDuration)
        // so it never trails rapid ⌘hjkl nav.
        Motion.ease(layer, keyPath: "borderColor", to: (isFocused ? Self.iris : Self.idleBorder).cgColor)
        Motion.ease(layer, keyPath: "shadowOpacity", to: isFocused ? Float(0.2) : Float(0))
    }

    /// A muted small-caps mono label (left) and its keybind (right), e.g. "BOTTOM  ⌘B".
    private static func makeMetaHeader(_ meta: PanelMeta) -> NSStackView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)

        let labelField = NSTextField(labelWithString: "")
        labelField.attributedStringValue = NSAttributedString(
            string: meta.label.uppercased(),
            attributes: [.font: font, .foregroundColor: NSColor(white: 0.92, alpha: 0.4), .kern: 1.2]
        )

        let keybindField = NSTextField(labelWithString: meta.keybind)
        keybindField.font = font
        keybindField.textColor = NSColor(white: 0.92, alpha: 0.3)
        keybindField.alignment = .right

        let stack = NSStackView(views: [labelField, keybindField])
        stack.orientation = .horizontal
        stack.distribution = .equalSpacing
        return stack
    }
}
