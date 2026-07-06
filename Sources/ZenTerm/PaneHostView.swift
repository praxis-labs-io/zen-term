import AppKit
import PaneKit

/// Hosts one leaf's terminal surface: the rounded/bordered frame over the canvas,
/// plus the iris focus halo (accent border + soft glow) when focused. Clicking
/// anywhere in the pane requests focus for its leaf.
final class PaneHostView: NSView {
    let paneID: PaneID
    private let onFocusRequest: (PaneID) -> Void
    private let pane = NSView()

    var isFocused: Bool = false { didSet { updateHalo() } }

    /// Inner breathing room between the pane border and the terminal content.
    private let padding: CGFloat = 10

    init(paneID: PaneID, content: NSView, background: NSColor, onFocusRequest: @escaping (PaneID) -> Void) {
        self.paneID = paneID
        self.onFocusRequest = onFocusRequest
        super.init(frame: .zero)

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
            content.topAnchor.constraint(equalTo: clip.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -padding),
        ])
        updateHalo()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest(paneID)
        super.mouseDown(with: event)
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
}
