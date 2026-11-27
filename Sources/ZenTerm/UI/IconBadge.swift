import AppKit
import TerminalKit

// A symbol or mark on a rounded chip: tinted by one chrome role, or a process's app-icon chip.
final class IconBadge: NSView, ThemeReapplying {
    enum Size {
        case small
        case regular

        var side: CGFloat {
            switch self {
            case .small: return 16
            case .regular: return 28
            }
        }

        var imageSide: CGFloat {
            switch self {
            case .small: return ChromeMetrics.Icon.sm
            case .regular: return 16
            }
        }

        var pointSize: CGFloat {
            switch self {
            case .small: return ChromeMetrics.Icon.sm
            case .regular: return ChromeMetrics.Icon.md
            }
        }
    }

    private enum Fill {
        case role((ChromeTheme) -> TerminalColor)
        case process(ProcessIcon)
    }

    private let icon = NSImageView()
    private let size: Size
    private var fill: Fill
    private var shown: ProcessIcon?
    private let sheen = NSView()
    private let sheenLayer = CAGradientLayer()
    private lazy var iconWidth = icon.widthAnchor.constraint(equalToConstant: size.imageSide)
    private lazy var iconHeight = icon.heightAnchor.constraint(equalToConstant: size.imageSide)

    convenience init(
        symbol: String, accessibilityDescription: String?, size: Size, role: @escaping (ChromeTheme) -> TerminalColor
    ) {
        self.init(size: size, fill: .role(role))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
        icon.symbolConfiguration = .init(pointSize: size.pointSize, weight: .semibold)
    }

    convenience init(
        image: NSImage?, accessibilityDescription: String?, size: Size, role: @escaping (ChromeTheme) -> TerminalColor
    ) {
        self.init(size: size, fill: .role(role))
        icon.image = image
        icon.setAccessibilityLabel(accessibilityDescription)
        sizeIcon(scale: 1)
    }

    convenience init(process: ProcessIcon, size: Size) {
        self.init(size: size, fill: .process(process))
        layer?.cornerRadius = ChromeMetrics.Radius.icon(size.side)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        ChipSheen.shape(sheenLayer, .chip)
        sheen.layer = sheenLayer
        sheen.wantsLayer = true
        sheen.frame = bounds
        sheen.autoresizingMask = [.width, .height]
        addSubview(sheen)
        show(process, animated: false)
    }

    private init(size: Size, fill: Fill) {
        self.size = size
        self.fill = fill
        super.init(frame: NSRect(x: 0, y: 0, width: size.side, height: size.side))
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.side),
            heightAnchor.constraint(equalToConstant: size.side),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var process: ProcessIcon? {
        if case .process(let process) = fill { return process }
        return nil
    }

    func show(_ process: ProcessIcon, animated: Bool = true) {
        guard case .process = fill, process != shown else { return }
        shown = process
        if animated, window != nil, let layer { Motion.crossfade(layer) }
        fill = .process(process)
        icon.image = process.image
        icon.setAccessibilityLabel(process.name)
        sizeIcon(scale: process.scale)
        reapplyTheme()
    }

    private func sizeIcon(scale: CGFloat) {
        iconWidth.constant = size.imageSide * scale
        iconHeight.constant = size.imageSide * scale
        NSLayoutConstraint.activate([iconWidth, iconHeight])
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        switch fill {
        case .role(let role):
            let color = role(chrome)
            layer?.backgroundColor = chrome.tint(color, alpha: ChromeTheme.badgeTint).cgColor
            icon.contentTintColor = color.nsColor
        case .process(let process):
            layer?.borderColor = chrome.fill(alpha: ChromeTheme.border).cgColor
            layer?.borderWidth = ChromeMetrics.Border.width
            let fill: NSColor
            switch process.look {
            case .brand(let brandFill, let glyph):
                fill = brandFill.nsColor
                icon.contentTintColor = glyph.nsColor
            case .artwork(let artworkFill):
                fill = artworkFill.nsColor
                icon.contentTintColor = nil
            case .purpose(let purpose):
                if let slot = purpose.hue(beside: chrome.accentSlot) {
                    let hue = slot.color(in: Theme.current.terminal)
                    fill = ChromeTheme.surface(
                        tint: chrome.tint(hue, alpha: ChromeTheme.badgeTint), over: chrome.chipRaised.nsColor)
                    icon.contentTintColor = hue.nsColor
                    break
                }
                fallthrough
            case .neutral, .catalog:
                fill = chrome.chipRaised.nsColor
                icon.contentTintColor = chrome.ink(.normal)
            case .muted:
                fill = chrome.chipRaised.nsColor
                icon.contentTintColor = chrome.ink(.muted)
            }
            layer?.backgroundColor = fill.cgColor
            sheenLayer.colors = ChipSheen.colors(.chip)
        }
    }

    var fillForTesting: CGColor? { layer?.backgroundColor }
    var shownProcessForTesting: ProcessIcon? { shown }
    var edgeForTesting: CGColor? { (layer?.borderWidth ?? 0) > 0 ? layer?.borderColor : nil }
    var hasSheenForTesting: Bool {
        sheen.superview === self && sheenLayer.colors?.count == ChipSheen.colors(.chip).count
    }
    var sheenLitFromTopForTesting: Bool { sheenLayer.startPoint.y > sheenLayer.endPoint.y && !sheen.isFlipped }
    var iconTintForTesting: NSColor? { icon.contentTintColor }
    var iconImageForTesting: NSImage? { icon.image }
    var iconFrameForTesting: NSRect { icon.frame }
}
