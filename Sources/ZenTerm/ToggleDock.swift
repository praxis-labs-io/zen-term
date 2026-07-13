import AppKit

/// The global footer toggle dock (bottom-right of the tab-bar row): a row of `IconButton`s
/// — split-h, split-v │ bottom drawer, right drawer, zoom │ repo picker, lazygit, one per
/// `ToolFloatCatalog` entry — grouped by thin dividers. Active toggles tint iris. Buttons
/// fire injected closures (routed through the window's chord handler, so they respect the
/// modals). `render` mirrors the active tab's overlay state plus the window's repo-picker
/// state.
final class ToggleDock: NSView {
    private let paletteBtn: IconButton
    private let bottomBtn: IconButton
    private let rightBtn: IconButton
    private let zoomBtn: IconButton
    private let lazygitBtn: IconButton
    private var toolFloatBtns: [String: IconButton] = [:]
    /// Every button + divider in the dock, retained so `reapplyTheme()` can re-color them all
    /// after a config change (some, like split-h/v and the dividers, have no other stored
    /// reference to reach through).
    private var allButtons: [IconButton] = []
    private var dividers: [NSView] = []
    /// The button row; the per-float buttons live at its tail and are rebuilt in place by
    /// `setToolFloats` when the catalog changes (a float added / edited / removed in Settings).
    private let stack = NSStackView()
    /// Retained so `setToolFloats` can wire freshly-built float buttons to the same action.
    private let onToolFloat: (ToolFloat) -> Void

    private static let iconPointSize: CGFloat = 11

    init(
        onSplitH: @escaping () -> Void, onSplitV: @escaping () -> Void,
        onPalette: @escaping () -> Void, onBottom: @escaping () -> Void,
        onRight: @escaping () -> Void, onZoom: @escaping () -> Void,
        onLazygit: @escaping () -> Void,
        toolFloats: [ToolFloat], onToolFloat: @escaping (ToolFloat) -> Void
    ) {
        self.onToolFloat = onToolFloat
        func button(_ symbol: String, _ label: String, _ onClick: @escaping () -> Void) -> IconButton {
            IconButton(symbol: symbol, pointSize: Self.iconPointSize, accessibilityLabel: label, onClick: onClick)
        }
        let splitH = button("rectangle.split.1x2", "Split horizontally", onSplitH)  // ⌘- stacked
        let splitV = button("rectangle.split.2x1", "Split vertically", onSplitV)  // ⌘⇧\ side-by-side
        paletteBtn = button("command", "Command palette", onPalette)  // ⌘P
        bottomBtn = button("rectangle.bottomthird.inset.filled", "Toggle bottom drawer", onBottom)  // ⌘B
        rightBtn = button("rectangle.trailingthird.inset.filled", "Toggle right drawer", onRight)  // ⌘\
        zoomBtn = button("arrow.up.left.and.arrow.down.right", "Toggle zoom", onZoom)  // ⌘F
        lazygitBtn = button("git", "Toggle lazygit", onLazygit)  // ⌘G — bundled git mark
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        allButtons = [splitH, splitV, bottomBtn, rightBtn, zoomBtn, paletteBtn, lazygitBtn]
        let dividerA = Self.divider()
        let dividerB = Self.divider()
        dividers = [dividerA, dividerB]

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [splitH, splitV, dividerA, bottomBtn, rightBtn, zoomBtn, dividerB, paletteBtn, lazygitBtn] {
            stack.addArrangedSubview(view)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setToolFloats(toolFloats)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Test hook: the ids of the per-float buttons currently mounted in the dock.
    var toolFloatButtonIDsForTesting: Set<String> { Set(toolFloatBtns.keys) }

    /// Test hooks: whether each drawer toggle currently shows its busy activity dot (ZEN-107).
    var bottomActivityForTesting: Bool { bottomBtn.showsActivity }
    var rightActivityForTesting: Bool { rightBtn.showsActivity }

    /// Rebuild the per-float buttons at the tail of the dock from the current catalog — called on
    /// init and whenever a config change adds / edits / removes a float, so the dock reflects it with
    /// no relaunch. The fixed buttons and dividers are untouched; the caller re-runs `render` after
    /// to restore active states.
    func setToolFloats(_ toolFloats: [ToolFloat]) {
        for button in toolFloatBtns.values {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        allButtons.removeAll { button in toolFloatBtns.values.contains { $0 === button } }
        toolFloatBtns = [:]
        for spec in toolFloats {
            let btn = IconButton(
                symbol: spec.icon, pointSize: Self.iconPointSize, accessibilityLabel: spec.title
            ) { [weak self] in self?.onToolFloat(spec) }
            toolFloatBtns[spec.id] = btn
            allButtons.append(btn)
            stack.addArrangedSubview(btn)
        }
    }

    /// Mirror the active tab's overlay state (drawers, lazygit, zoom) and the window's
    /// repo picker; split buttons are momentary and have no active state. A modal float
    /// (lazygit / tool float) covers the whole tab, so while one is open the zoom and drawer
    /// pips dim — their state is hidden behind it and returns when it closes. Otherwise the
    /// drawer tints reflect what's visible: a zoomed pane hides both drawers (neither lit), a
    /// zoomed drawer hides its sibling (only its own lit).
    func render(overlay: OverlayState, paletteOpen: Bool) {
        paletteBtn.isActive = paletteOpen
        lazygitBtn.isActive = overlay.isLazygitOpen
        for (id, btn) in toolFloatBtns { btn.isActive = overlay.activeToolFloatID == id }

        // A float covers the tab, so zoom/drawer state beneath it would read as lit-but-hidden.
        let floatCoversTab = overlay.isLazygitOpen || overlay.activeToolFloatID != nil
        if floatCoversTab {
            zoomBtn.isActive = false
            bottomBtn.isActive = false
            rightBtn.isActive = false
        } else {
            zoomBtn.isActive = overlay.zoomed != nil
            switch overlay.zoomed {
            case nil:
                bottomBtn.isActive = overlay.isBottomOpen
                rightBtn.isActive = overlay.isRightOpen
            case .pane:
                bottomBtn.isActive = false
                rightBtn.isActive = false
            case .bottomDrawer:
                bottomBtn.isActive = true
                rightBtn.isActive = false
            case .rightDrawer:
                bottomBtn.isActive = false
                rightBtn.isActive = true
            }
        }

        // A busy drawer earns a dot so its live process is evident from the footer, whether the
        // drawer is currently shown or hidden (ZEN-107).
        bottomBtn.showsActivity = overlay.bottomBusy
        rightBtn.showsActivity = overlay.rightBusy
    }

    /// Re-apply the live chrome colors to every button + divider after a config change — no
    /// relaunch. Each `IconButton` already reads `Theme.current` fresh; this just re-triggers
    /// that read. The dividers bake their color in once at build time, so it's reset explicitly.
    func reapplyTheme() {
        for button in allButtons { button.reapplyTheme() }
        let dividerColor = Theme.current.chrome.ink(alpha: 0.10).cgColor
        for divider in dividers { divider.layer?.backgroundColor = dividerColor }
    }

    /// A thin 1×12 vertical divider matching the demo's group separators.
    private static func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.10).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return v
    }
}
