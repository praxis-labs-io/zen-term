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
    private let zoomButton: CornerButton
    private let hideButton: CornerButton?

    /// Invoked when the corner zoom action button is clicked — the chrome exits zoom.
    var onZoomExit: (() -> Void)?

    var isFocused: Bool = false { didSet { updateHalo() } }

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

    init(content: NSView, background: NSColor, meta: PanelMeta?,
         hideButton hideSpec: (glyph: String, onHide: () -> Void)? = nil,
         onFocusRequest: @escaping () -> Void) {
        self.onFocusRequest = onFocusRequest
        self.zoomButton = CornerButton(glyph: "⤢")
        self.hideButton = hideSpec.map { CornerButton(glyph: $0.glyph) }
        super.init(frame: .zero)
        zoomButton.onClick = { [weak self] in self?.onZoomExit?() }
        if let hideSpec { hideButton?.onClick = hideSpec.onHide }

        wantsLayer = true
        pane.wantsLayer = true
        pane.layer?.cornerRadius = 12
        pane.layer?.masksToBounds = false          // glow must escape bounds; content clip is on a mask below
        pane.layer?.borderWidth = 1
        addSubview(pane)

        content.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSView()                         // inner clip so terminal content stays inside the radius
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = background.cgColor   // fills the padding ring with the terminal bg
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

    /// Top-right corner slot (22×20, 8pt inset) shared by the corner action buttons.
    private func cornerConstraints(for button: NSView) -> [NSLayoutConstraint] {
        [
            button.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 20),
        ]
    }

    private static let iris = NSColor(srgbRed: 0xc4 / 255.0, green: 0xa7 / 255.0, blue: 0xe7 / 255.0, alpha: 1)
    private static let idleBorder = NSColor(white: 1, alpha: 0.08)

    private func updateHalo() {
        guard let layer = pane.layer else { return }
        if isFocused {
            layer.borderColor = Self.iris.cgColor
            layer.shadowColor = Self.iris.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 10
            layer.shadowOffset = .zero
        } else {
            layer.borderColor = Self.idleBorder.cgColor
            layer.shadowOpacity = 0
        }
    }

    /// A small corner action button: a white glyph with no background until hover
    /// (matching the tab bar's "+"), pointing-hand cursor, click fires `onClick`.
    /// Used for the unzoom control and the drawer hide controls.
    private final class CornerButton: NSView {
        var onClick: (() -> Void)?
        private let glyph: NSTextField
        private var trackingArea: NSTrackingArea?
        private var isHovered = false { didSet { update() } }

        init(glyph glyphChar: String) {
            self.glyph = NSTextField(labelWithString: glyphChar)
            super.init(frame: .zero)
            isHidden = true
            wantsLayer = true
            layer?.cornerRadius = 5
            glyph.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            glyph.alignment = .center
            glyph.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            translatesAutoresizingMaskIntoConstraints = false
            update()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds,
                                     options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                     owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }
        override func mouseDown(with event: NSEvent) { onClick?() }   // consumes — no focus bubble
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

        private func update() {
            layer?.backgroundColor = (isHovered ? NSColor(white: 1, alpha: 0.12) : .clear).cgColor
            glyph.textColor = NSColor(white: 0.95, alpha: isHovered ? 1.0 : 0.65)
        }
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
