import AppKit

/// The footer toolbar (bottom-right of the tab-bar row): a row of `IconButton`s — new tab │
/// split-h, split-v, bottom drawer, right drawer, focus mode │ palette │ one per
/// `ToolFloatCatalog` entry — grouped by thin dividers. Active toggles tint iris. Buttons fire
/// injected closures (routed through the window's chord handler, so they respect the modals).
/// Any built-in button can be hidden by `hide-toolbar-buttons`, and a float's `toolbar:false`
/// hides its button while the tool isn't running (a running tool always keeps its button, dot and
/// all); a divider only renders between two groups that both show something.
final class ToggleDock: NSView {
    private let paletteBtn: IconButton
    private let bottomBtn: IconButton
    private let rightBtn: IconButton
    /// The built-in Scratch float's button. Fixed rather than one of the `toolFloatBtns` below,
    /// since it comes from the catalog's built-ins and not from the config.
    private let scratchBtn: IconButton
    private let zoomBtn: IconButton
    /// The built-in buttons keyed by their config slug, so `refreshVisibility` can hide by
    /// `ToolbarButton` — the same instances the named properties above hold. The one place the
    /// button set is stated: `allButtons`'s fixed portion and the stack order both derive from it
    /// (via `ToolbarButton.allCases` / `.groups`), so a new button can't join one registry and
    /// silently miss another.
    private var fixedButtons: [ToolbarButton: IconButton] = [:]
    private var hiddenButtons: Set<ToolbarButton>
    private var toolFloatBtns: [String: IconButton] = [:]
    /// Floats declaring `toolbar:false`. Their buttons are built and hidden rather than skipped:
    /// `render` surfaces one while its tool is running (shown, or live in background), because the
    /// button's dot is the only trace a hidden persistent float has — filtering it out
    /// would leave a live process with no visible handle.
    private var toolbarHiddenFloatIDs: Set<String> = []
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
        onNewTab: @escaping () -> Void,
        onSplitH: @escaping () -> Void, onSplitV: @escaping () -> Void,
        onPalette: @escaping () -> Void, onBottom: @escaping () -> Void,
        onRight: @escaping () -> Void, onZoom: @escaping () -> Void,
        toolFloats: [ToolFloat], onToolFloat: @escaping (ToolFloat) -> Void,
        hiddenButtons: Set<ToolbarButton> = []
    ) {
        self.onToolFloat = onToolFloat
        self.hiddenButtons = hiddenButtons
        // Each toggle's tooltip resolves its glyph from the live keymap, so it tracks user rebinds.
        func button(
            _ symbol: String, _ label: String, _ action: KeyInterceptor.ReservedChord,
            _ onClick: @escaping () -> Void
        ) -> IconButton {
            IconButton(
                symbol: symbol, pointSize: Self.iconPointSize, accessibilityLabel: label,
                shortcut: { CommandCatalog.spec(for: action).shortcut }, onClick: onClick)
        }
        let newTab = button("plus", "New tab", .newTab, onNewTab)
        let splitH = button("rectangle.split.1x2", "Split horizontally", .splitHorizontal, onSplitH)
        let splitV = button("rectangle.split.2x1", "Split vertically", .splitVertical, onSplitV)
        paletteBtn = button("command", "Command palette", .toggleCommandPalette, onPalette)
        bottomBtn = button("rectangle.bottomthird.inset.filled", "Toggle bottom drawer", .toggleBottomDrawer, onBottom)
        rightBtn = button("rectangle.trailingthird.inset.filled", "Toggle right drawer", .toggleRightDrawer, onRight)
        // Wired off the `onToolFloat` parameter, not the stored property: this runs before
        // `super.init`, so nothing here may touch `self`.
        let scratch = ToolFloat.scratch
        scratchBtn = button(
            scratch.icon, scratch.title, .toggleToolFloat(scratch.id), { onToolFloat(scratch) })
        zoomBtn = button("arrow.up.left.and.arrow.down.right", "Focus mode", .toggleZoom, onZoom)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        fixedButtons = [
            .newTab: newTab, .splitHorizontal: splitH, .splitVertical: splitV,
            .bottomDrawer: bottomBtn, .rightDrawer: rightBtn, .scratch: scratchBtn,
            .focusMode: zoomBtn,
            .commandPalette: paletteBtn,
        ]
        // Derived from the map, never restated: recolor order tracks `allCases`, and the stack
        // interleaves each `ToolbarButton.groups` group with its trailing divider — dividers[i]
        // separates group i from group i+1, the float tail being the last group.
        // `refreshVisibility` leans on that indexing.
        allButtons = ToolbarButton.allCases.compactMap { fixedButtons[$0] }
        dividers = ToolbarButton.groups.map { _ in Self.divider() }

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, group) in ToolbarButton.groups.enumerated() {
            for view in group.compactMap({ fixedButtons[$0] }) {
                stack.addArrangedSubview(view)
            }
            stack.addArrangedSubview(dividers[index])
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

    /// Test hook: the ids of the per-float buttons currently **visible** in the dock, left to right.
    /// Read off the arranged subviews rather than `toolFloatBtns`, so it reports the order the user
    /// actually sees — a dictionary's keys couldn't, and the float order is the thing under test.
    /// Visibility-filtered because a `toolbar:false` float's button is mounted hidden.
    var toolFloatButtonIDsForTesting: [String] {
        stack.arrangedSubviews.compactMap { view in
            guard !view.isHidden else { return nil }
            return toolFloatBtns.first { $0.value === view }?.key
        }
    }

    /// Test hooks: whether each drawer toggle currently shows its busy activity dot.
    var bottomActivityForTesting: Bool { bottomBtn.showsActivity }
    var rightActivityForTesting: Bool { rightBtn.showsActivity }

    /// Test hooks: the Scratch button's two states. Separate from `dottedToolFloatIDsForTesting`
    /// below, which only walks the config-driven float tail. `isActive` is the one the
    /// `floatCoversTab` ordering in `render` turns on, so it needs a hook of its own.
    var scratchActivityForTesting: Bool { scratchBtn.showsActivity }
    var scratchActiveForTesting: Bool { scratchBtn.isActive }

    /// Test hook: the ids of the per-float buttons currently showing their live-in-background dot.
    /// Reads the button's real state, not a mirror, so it can't pass while the dot is
    /// actually dark.
    var dottedToolFloatIDsForTesting: Set<String> {
        Set(toolFloatBtns.filter { $0.value.showsActivity }.keys)
    }

    /// Test hook: whether the fixed new-tab button is mounted and visible (it moved from
    /// the tab strip into the dock, so it must be present by default regardless of tab overflow).
    /// The visibility check matters: a hidden arranged subview stays in `arrangedSubviews`, so
    /// without it this hook would pass while the button is gone from the screen.
    var hasNewTabButtonForTesting: Bool {
        stack.arrangedSubviews.contains {
            ($0 as? IconButton)?.accessibilityLabel() == "New tab" && !$0.isHidden
        }
    }

    /// Test hook: the visible toolbar left-to-right — buttons as their accessibility labels,
    /// dividers as `"│"`. Reads the real arranged subviews and their `isHidden`, so it reports
    /// exactly what the user sees, grouping included.
    var visibleLayoutForTesting: [String] {
        stack.arrangedSubviews.filter { !$0.isHidden }.map { view in
            (view as? IconButton)?.accessibilityLabel() ?? "│"
        }
    }

    /// Rebuild the per-float buttons at the tail of the dock from the current catalog — called on
    /// init and whenever a config change adds / edits / removes a float, so the dock reflects it with
    /// no relaunch. Every float gets a button; a `toolbar:false` float's starts hidden and `render`
    /// surfaces it while its tool runs (see `toolbarHiddenFloatIDs`). Handling visibility inside the
    /// dock keeps every caller passing the full catalog, so pruning and the palette never see a
    /// narrowed list. The fixed buttons and dividers are untouched; the caller re-runs `render`
    /// after to restore active states.
    func setToolFloats(_ toolFloats: [ToolFloat]) {
        for button in toolFloatBtns.values {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        allButtons.removeAll { button in toolFloatBtns.values.contains { $0 === button } }
        toolFloatBtns = [:]
        toolbarHiddenFloatIDs = Set(toolFloats.filter { !$0.showsInToolbar }.map(\.id))
        for spec in toolFloats {
            // Like the fixed buttons, resolve the glyph from the live keymap so the tooltip tracks
            // user rebinds of the float's `toggle_float:<id>` chord.
            let btn = IconButton(
                symbol: spec.icon, pointSize: Self.iconPointSize, accessibilityLabel: spec.title,
                shortcut: { CommandCatalog.spec(for: .toggleToolFloat(spec.id)).shortcut }
            ) { [weak self] in self?.onToolFloat(spec) }
            btn.isHidden = !spec.showsInToolbar
            toolFloatBtns[spec.id] = btn
            allButtons.append(btn)
            stack.addArrangedSubview(btn)
        }
        refreshVisibility()
    }

    /// Hide/show built-in buttons per the `hide-toolbar-buttons` set. Visual only: `render` keeps
    /// writing active state to hidden buttons, so un-hiding needs no restoration pass.
    func setHiddenButtons(_ hidden: Set<ToolbarButton>) {
        hiddenButtons = hidden
        refreshVisibility()
    }

    /// Apply button visibility and recompute the dividers. The stack detaches hidden arranged
    /// subviews (`detachesHiddenViews`), so a hidden button or divider leaves no gap. Divider `i`
    /// separates groups 0…i from group i+1: it shows iff something is visible on both sides, which
    /// yields no leading, trailing, or doubled divider for every hide combination (an empty middle
    /// group collapses to a single divider between its neighbors).
    private func refreshVisibility() {
        for (button, view) in fixedButtons {
            view.isHidden = hiddenButtons.contains(button)
        }
        let groupVisible =
            ToolbarButton.groups.map { group in
                group.contains { !hiddenButtons.contains($0) }
            } + [toolFloatBtns.values.contains { !$0.isHidden }]
        for (index, divider) in dividers.enumerated() {
            divider.isHidden = !(groupVisible[...index].contains(true) && groupVisible[index + 1])
        }
    }

    /// Mirror the active tab's overlay state (drawers, zoom) and the window's shown tool float
    /// (`floatID` — floats are window-level, so they don't ride a tab's `OverlayState`); split
    /// buttons are momentary and have no active state. A modal tool
    /// float covers the whole tab, so while one is open the zoom and drawer
    /// pips dim — their state is hidden behind it and returns when it closes. Otherwise the
    /// drawer tints reflect what's visible: a zoomed pane hides both drawers (neither lit), a
    /// zoomed drawer hides its sibling (only its own lit).
    ///
    /// `isLiveInBackground` dots a float whose tool is still running while its card is dismissed —
    /// the only trace a hidden persistent float has. Passed as a query rather than a set so the
    /// "live but not shown" rule keeps one definition, on the controller that owns the registry.
    func render(
        overlay: OverlayState, floatID: String?, paletteOpen: Bool,
        isLiveInBackground: (String) -> Bool = { _ in false }
    ) {
        paletteBtn.isActive = paletteOpen
        for (id, btn) in toolFloatBtns {
            let isLive = isLiveInBackground(id)
            btn.isActive = floatID == id
            btn.showsActivity = isLive
            // A `toolbar:false` button surfaces while its tool is running — shown, or live behind
            // the scenes (the dot is the only trace a hidden persistent float has) — and hides
            // again when the tool dies, so a live process always keeps a visible handle.
            btn.isHidden = toolbarHiddenFloatIDs.contains(id) && floatID != id && !isLive
        }
        refreshVisibility()  // a surfaced or re-hidden float button moves the tools divider

        // Above the `floatCoversTab` branch below, deliberately: that branch dims the buttons whose
        // state is hidden behind a card, and this button IS the card when Scratch is the one open.
        scratchBtn.isActive = floatID == ToolFloat.scratch.id
        scratchBtn.showsActivity = isLiveInBackground(ToolFloat.scratch.id)

        // A float covers the tab, so zoom/drawer state beneath it would read as lit-but-hidden.
        let floatCoversTab = floatID != nil
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
        // drawer is currently shown or hidden.
        bottomBtn.showsActivity = overlay.bottomBusy
        rightBtn.showsActivity = overlay.rightBusy
    }

    /// Re-apply the live chrome colors to every button + divider after a config change — no
    /// relaunch. Each `IconButton` already reads `Theme.current` fresh; this just re-triggers
    /// that read. The dividers bake their color in once at build time, so it's reset explicitly.
    func reapplyTheme() {
        for button in allButtons { button.reapplyTheme() }
        let dividerColor = Theme.current.chrome.fill(alpha: ChromeTheme.hairline).cgColor
        for divider in dividers { divider.layer?.backgroundColor = dividerColor }
    }

    /// A thin 1×12 vertical divider matching the demo's group separators.
    private static func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.hairline).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return v
    }
}
