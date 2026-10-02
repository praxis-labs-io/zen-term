import AppKit

// A tab drawn as its main pane and two drawers, not to scale: the region being edited grows to fit its command.
final class WorkspaceTabDrawing: NSView {
    static let height: CGFloat = 232
    static let launchFocusShortcut = "⌘L"
    private static let inset: CGFloat = 8
    private static let gap: CGFloat = 8
    private static let railThickness: CGFloat = 28
    private static let bottomHeight: CGFloat = 72
    private static let rightWidth: CGFloat = 216
    private static let focusedRightWidth: CGFloat = 240
    private static let minRightWidth: CGFloat = 140
    private static let minMainWidth: CGFloat = 200

    var onCommandChanged: ((Workspace.Region, String) -> Void)?
    var onDrawerClosed: ((Workspace.Region) -> Void)?
    var onOpenFocused: ((Workspace.Region) -> Void)?
    var onExitUp: (() -> Void)?
    var onExitDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    private let regions: [Workspace.Region: RegionCommandField]
    private let rails: [Workspace.Region: DrawerRail]
    private var openedEmpty: Set<Workspace.Region> = []
    private var tab = Workspace.Tab()
    private var tabIndex = 0
    private(set) var focusedRegion: Workspace.Region?

    init() {
        var regions: [Workspace.Region: RegionCommandField] = [:]
        for region in Workspace.Region.allCases { regions[region] = RegionCommandField(region: region) }
        self.regions = regions
        rails = [.right: DrawerRail(region: .right), .bottom: DrawerRail(region: .bottom)]
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        for field in regions.values { wire(field) }
        for rail in rails.values { wire(rail) }
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func render(tab: Workspace.Tab, index: Int, opensFocusedIn launchRegion: Workspace.Region?) {
        if index != tabIndex { openedEmpty = [] }
        self.tab = tab
        tabIndex = index
        for (region, field) in regions {
            field.setText(tab.command(in: region) ?? "")
            field.setOpensFocused(region == launchRegion)
        }
        needsLayout = true
    }

    func isOpen(_ region: Workspace.Region) -> Bool {
        region == .main || tab.command(in: region) != nil || openedEmpty.contains(region)
    }

    func region(_ region: Workspace.Region) -> RegionCommandField? { regions[region] }

    func rail(_ region: Workspace.Region) -> DrawerRail? { rails[region] }

    func stop(for region: Workspace.Region) -> NSView? {
        if isOpen(region) { return regions[region]?.field }
        return rails[region]
    }

    func focus(_ region: Workspace.Region) {
        guard let stop = stop(for: region) else { return }
        window?.makeFirstResponder(stop)
    }

    var focusStops: [NSView] { Workspace.Region.allCases.compactMap(stop(for:)) }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        layer?.borderColor = chrome.fill(alpha: ChromeTheme.hairline).cgColor
        regions.values.forEach { $0.reapplyTheme() }
        rails.values.forEach { $0.reapplyTheme() }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let rightOpen = isOpen(.right)
        let bottomOpen = isOpen(.bottom)
        let rightWidth = rightOpen ? openRightWidth(total: width) : Self.railThickness
        let mainWidth = max(0, width - 2 * Self.inset - Self.gap - rightWidth)
        let lowerHeight = bottomOpen ? Self.bottomHeight : Self.railThickness
        let mainHeight = Self.height - 2 * Self.inset - Self.gap - lowerHeight
        let mainFrame = CGRect(x: Self.inset, y: Self.inset, width: mainWidth, height: mainHeight)
        let bottomFrame = CGRect(
            x: Self.inset, y: mainFrame.maxY + Self.gap, width: mainWidth, height: lowerHeight)
        let rightFrame = CGRect(
            x: mainFrame.maxX + Self.gap, y: Self.inset, width: rightWidth, height: Self.height - 2 * Self.inset)
        place(.main, open: true, frame: mainFrame)
        place(.right, open: rightOpen, frame: rightFrame)
        place(.bottom, open: bottomOpen, frame: bottomFrame)
    }

    private func place(_ region: Workspace.Region, open: Bool, frame: CGRect) {
        let field = regions[region]
        let rail = rails[region]
        if open {
            if let field, field.superview == nil { addSubview(field) }
            field?.frame = frame
            rail?.removeFromSuperview()
        } else {
            if let rail, rail.superview == nil { addSubview(rail) }
            rail?.frame = frame
            field?.removeFromSuperview()
        }
    }

    private func openRightWidth(total: CGFloat) -> CGFloat {
        let room = total - 2 * Self.inset - Self.gap
        guard let focusedRegion, let focused = regions[focusedRegion] else { return Self.rightWidth }
        let fit = focused.fittingTextWidth
        if focusedRegion == .right {
            return min(max(Self.focusedRightWidth, fit), room - Self.minMainWidth)
        }
        guard fit > room - Self.rightWidth else { return Self.rightWidth }
        return max(Self.minRightWidth, room - fit)
    }

    func openFocusedAtFocusedRegion() -> Bool {
        guard let focusedRegion, isOpen(focusedRegion) else { return false }
        onOpenFocused?(focusedRegion)
        return true
    }

    private func wire(_ field: RegionCommandField) {
        let region = field.region
        field.onChange = { [weak self] text in
            self?.onCommandChanged?(region, text)
            self?.needsLayout = true
        }
        field.onFocused = { [weak self] in
            self?.focusedRegion = region
            self?.needsLayout = true
        }
        field.onEndEditing = { [weak self] in self?.fieldEnded(region) }
        field.onEdge = { [weak self] edge in self?.move(from: region, edge) }
        field.onTab = { [weak self] in self?.step(from: region, by: 1) }
        field.onBacktab = { [weak self] in self?.step(from: region, by: -1) }
        field.onOpenFocusedHere = { [weak self] in self?.onOpenFocused?(region) }
    }

    private func wire(_ rail: DrawerRail) {
        let region = rail.region
        rail.onOpen = { [weak self] in self?.openDrawer(region) }
        rail.onEdge = { [weak self] edge in self?.move(from: region, edge) }
        rail.onTab = { [weak self] in self?.step(from: region, by: 1) }
        rail.onBacktab = { [weak self] in self?.step(from: region, by: -1) }
    }

    private func openDrawer(_ region: Workspace.Region) {
        openedEmpty.insert(region)
        needsLayout = true
        layoutSubtreeIfNeeded()
        focus(region)
    }

    private func fieldEnded(_ region: Workspace.Region) {
        if focusedRegion == region { focusedRegion = nil }
        needsLayout = true
        guard region != .main, tab.command(in: region) == nil else { return }
        openedEmpty.remove(region)
        onDrawerClosed?(region)
    }

    private func move(from region: Workspace.Region, _ edge: RegionCommandField.Edge) {
        switch (region, edge) {
        case (.main, .right), (.bottom, .right): focus(.right)
        case (.main, .down): focus(.bottom)
        case (.bottom, .up): focus(.main)
        case (.right, .left): focus(.main)
        case (.main, .up), (.right, .up): onExitUp?()
        case (.bottom, .down), (.right, .down): onExitDown?()
        default: break
        }
    }

    private func step(from region: Workspace.Region, by delta: Int) {
        let order = Workspace.Region.allCases
        guard let index = order.firstIndex(of: region) else { return }
        let next = index + delta
        if next < 0 {
            (onBacktab ?? onExitUp)?()
        } else if next >= order.count {
            (onTab ?? onExitDown)?()
        } else {
            focus(order[next])
        }
    }
}
