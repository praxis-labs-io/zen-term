import AppKit
import TabKit

final class ToggleDock: NSView {
    private let bottomBtn: IconButton
    private let rightBtn: IconButton
    private let scratchBtn: IconButton
    private let zoomBtn: IconButton
    private var fixedButtons: [ToolbarButton: IconButton] = [:]
    private var hiddenButtons: Set<ToolbarButton>
    /// Held across renders, since `surface(_:busy:onScreen:)` only re-decides an off-screen button.
    private var surfacedButtons: Set<ToolbarButton> = []
    private var surfacedTab: TabID?
    private var toolFloatBtns: [String: IconButton] = [:]
    /// Built and hidden, not skipped: the dot is a hidden live float's only handle.
    private var toolbarHiddenFloatIDs: Set<String> = []
    private var allButtons: [IconButton] = []
    private var dividers: [NSView] = []
    private let stack = NSStackView()
    private let onToolFloat: (ToolFloat) -> Void

    private static let iconPointSize: CGFloat = 11

    init(
        onNewTab: @escaping () -> Void,
        onSplitH: @escaping () -> Void, onSplitV: @escaping () -> Void,
        onBottom: @escaping () -> Void,
        onRight: @escaping () -> Void, onZoom: @escaping () -> Void,
        toolFloats: [ToolFloat], onToolFloat: @escaping (ToolFloat) -> Void,
        hiddenButtons: Set<ToolbarButton> = []
    ) {
        self.onToolFloat = onToolFloat
        self.hiddenButtons = hiddenButtons
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
        bottomBtn = button("rectangle.bottomthird.inset.filled", "Toggle bottom drawer", .toggleBottomDrawer, onBottom)
        rightBtn = button("rectangle.trailingthird.inset.filled", "Toggle right drawer", .toggleRightDrawer, onRight)
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
        ]
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

    var toolFloatButtonIDsForTesting: [String] {
        stack.arrangedSubviews.compactMap { view in
            guard !view.isHidden else { return nil }
            return toolFloatBtns.first { $0.value === view }?.key
        }
    }

    var bottomActivityForTesting: Bool { bottomBtn.showsActivity }
    var rightActivityForTesting: Bool { rightBtn.showsActivity }

    var scratchActivityForTesting: Bool { scratchBtn.showsActivity }

    var rightActivityStateForTesting: SurfaceAttention { rightBtn.activityState }
    var scratchActivityStateForTesting: SurfaceAttention { scratchBtn.activityState }
    var rightActivityColorForTesting: NSColor { rightBtn.activityColorForTesting }
    var scratchActiveForTesting: Bool { scratchBtn.isActive }
    var rightActiveForTesting: Bool { rightBtn.isActive }

    var dottedToolFloatIDsForTesting: Set<String> {
        Set(toolFloatBtns.filter { $0.value.showsActivity }.keys)
    }

    var hasNewTabButtonForTesting: Bool {
        stack.arrangedSubviews.contains {
            ($0 as? IconButton)?.accessibilityLabel() == "New tab" && !$0.isHidden
        }
    }

    var visibleLayoutForTesting: [String] {
        stack.arrangedSubviews.filter { !$0.isHidden }.map { view in
            (view as? IconButton)?.accessibilityLabel() ?? "│"
        }
    }

    func setToolFloats(_ toolFloats: [ToolFloat]) {
        for button in toolFloatBtns.values {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        allButtons.removeAll { button in toolFloatBtns.values.contains { $0 === button } }
        toolFloatBtns = [:]
        toolbarHiddenFloatIDs = Set(toolFloats.filter { !$0.showsInToolbar }.map(\.id))
        for spec in toolFloats {
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

    func setHiddenButtons(_ hidden: Set<ToolbarButton>) {
        hiddenButtons = hidden
        refreshVisibility()
    }

    private func refreshVisibility() {
        for (button, view) in fixedButtons {
            view.isHidden = !isVisible(button)
        }
        let groupVisible =
            ToolbarButton.groups.map { group in
                group.contains { isVisible($0) }
            } + [toolFloatBtns.values.contains { !$0.isHidden }]
        for (index, divider) in dividers.enumerated() {
            divider.isHidden = !(groupVisible[...index].contains(true) && groupVisible[index + 1])
        }
    }

    private func isVisible(_ button: ToolbarButton) -> Bool {
        !hiddenButtons.contains(button) || surfacedButtons.contains(button)
    }

    func render(
        overlay: OverlayState, floatID: String?, tab: TabID? = nil,
        isLiveInBackground: (String) -> Bool = { _ in false },
        isFloatBusy: (String) -> Bool = { _ in false },
        drawerAttention: (DrawerEdge) -> SurfaceAttention = { _ in .idle },
        floatAttention: (String) -> SurfaceAttention = { _ in .idle }
    ) {
        if tab != surfacedTab {
            surfacedTab = tab
            surfacedButtons = []
        }

        for (id, btn) in toolFloatBtns {
            let isLive = isLiveInBackground(id)
            let attention = floatAttention(id)
            btn.isActive = floatID == id
            btn.activityState = attention
            btn.showsActivity = isLive || attention != .idle
            btn.isHidden = toolbarHiddenFloatIDs.contains(id) && floatID != id && !isLive
        }

        scratchBtn.isActive = floatID == ToolFloat.scratch.id
        let scratchAttention = floatAttention(ToolFloat.scratch.id)
        scratchBtn.activityState = scratchAttention
        scratchBtn.showsActivity =
            isLiveInBackground(ToolFloat.scratch.id) || scratchAttention != .idle

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

        let bottomAttention = drawerAttention(.bottom)
        let rightAttention = drawerAttention(.right)
        bottomBtn.activityState = bottomAttention
        rightBtn.activityState = rightAttention
        bottomBtn.showsActivity = overlay.bottomBusy || bottomAttention != .idle
        rightBtn.showsActivity = overlay.rightBusy || rightAttention != .idle

        surface(.bottomDrawer, busy: bottomBtn.showsActivity, onScreen: bottomBtn.isActive)
        surface(.rightDrawer, busy: rightBtn.showsActivity, onScreen: rightBtn.isActive)
        surface(
            .scratch, busy: isFloatBusy(ToolFloat.scratch.id) || scratchAttention != .idle,
            onScreen: scratchBtn.isActive)
        refreshVisibility()
    }

    /// Holds while on screen, so the button doesn't vanish under the pointer or flash on open.
    private func surface(_ button: ToolbarButton, busy: Bool, onScreen: Bool) {
        guard hiddenButtons.contains(button) else {
            surfacedButtons.remove(button)
            return
        }
        guard !onScreen else { return }
        if busy {
            surfacedButtons.insert(button)
        } else {
            surfacedButtons.remove(button)
        }
    }

    func reapplyTheme() {
        for button in allButtons { button.reapplyTheme() }
        let dividerColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor
        for divider in dividers { divider.layer?.backgroundColor = dividerColor }
    }

    static func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return v
    }
}
