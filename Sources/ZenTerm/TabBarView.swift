import AppKit
import TabKit

/// Attention signaled by a tab's number. Agent input stays stronger than command completion.
enum TabAttentionState {
    case idle, completed, waiting
}

struct TabBarItem {
    let id: TabID
    let index: Int  // 1-based number shown before the title
    let title: String
    let isActive: Bool
    let attentionState: TabAttentionState
}

/// The bottom-left numbered tab bar. Stateless beyond its last rendered snapshot;
/// selection/close flow out through callbacks. Clicking a tab selects it; middle-clicking a tab
/// closes it. The active tab is marked with an accent underline. When the tabs overflow the bar they
/// scroll horizontally with no scroller, the active tab is kept in view, and each edge fades
/// when tabs sit off that side. New-tab lives in the footer dock, not here.
///
/// The chips are laid out by explicit frame rather than a stack view: inside a scroll view an
/// `NSStackView`'s intrinsic width isn't authoritative, so the document view stayed capped and
/// later chips were clipped. Manual layout (recomputed in `layout()`, so it tracks window
/// resizes) keeps the content width exact.
final class TabBarView: NSView, NSTextFieldDelegate {
    private let onSelect: (TabID) -> Void
    private let onClose: (TabID) -> Void
    /// Reports a committed rename. An empty string is the reset: the caller clears the tab's
    /// pinned title so it goes back to its live cwd title.
    private let onRename: (TabID, String) -> Void

    static let height: CGFloat = 30

    private static let leadingInset: CGFloat = 12
    private static let chipSpacing: CGFloat = 4
    private static let chipHeight: CGFloat = 22
    /// The chips ride 6pt up so they read as centered in the whole band between the terminal
    /// content and the window edge, matching the footer dock's nudge.
    private static let bandNudge: CGFloat = 6
    /// The last ~28pt at each edge over which overflowing tabs dissolve into the backdrop.
    private static let fadeWidth: CGFloat = 28

    fileprivate static var activeInk: NSColor { Theme.current.chrome.ink(.normal) }
    fileprivate static var idleInk: NSColor {
        Theme.current.chrome.ink(.subtle)
    }
    /// Test hooks: the inks the bar really paints, so a test cannot restate the numbers and pass
    /// against its own copy of them.
    static var activeInkForTesting: NSColor { activeInk }
    static var idleInkForTesting: NSColor { idleInk }

    /// Horizontal scroll host for the chips — no visible scroller; overflow scrolls and fades.
    private let scrollView = NSScrollView()
    /// The scrolling content, frame-managed. Holds the chips and owns the tracer layer so the
    /// underline scrolls with them. Not flipped — bottom-left origin matches the tracer math.
    private let docView = NSView()
    /// The current chips, in order, retained so `layout()` can re-frame them on resize.
    private var chips: [Chip] = []
    /// Edge alpha ramp applied as the scroll view's layer mask (fixed in window space, so it
    /// doesn't scroll): opaque across the strip, fading to clear over the leading/trailing
    /// `fadeWidth` when tabs are scrolled off that side. Theme-independent — only the alpha
    /// channel is used to dissolve tabs into whatever is behind them (like `FloatShadow`'s
    /// documented exception), so no chrome color is involved. Each edge's ramp is toggled
    /// fully-opaque when nothing overflows past it.
    private let edgeFade = CAGradientLayer()
    /// A single accent underline that slides along the bar to the active tab (a tracer),
    /// rather than a per-chip underline snapping on/off.
    /// Owned (not an NSView backing layer) so its anchor point is ours: a left-edge anchor
    /// lets us keyframe the left edge and width directly, for a stretch that only reaches
    /// toward the target rather than growing symmetrically about the center.
    private let tracer = CALayer()
    private var activeTabID: TabID?
    /// The last snapshot handed to `render(_:)`, retained so `reapplyTheme()` can re-render it
    /// after a theme swap without the caller re-supplying the tab list.
    private var lastItems: [TabBarItem] = []
    /// How long the tracer takes to reach the newly-selected tab — matched to the canvas
    /// page-slide (0.28s) so the two land together.
    private static let tracerDuration: CFTimeInterval = 0.28
    /// The in-place rename editor and the tab it belongs to, non-nil only while one is open.
    private var renameEditor: NSTextField?
    private var renamingID: TabID?
    /// Guards the teardown against `controlTextDidEndEditing` re-entering it as the editor is
    /// pulled out of the view tree.
    private var isEndingRename = false

    init(
        onSelect: @escaping (TabID) -> Void,
        onClose: @escaping (TabID) -> Void,
        onRename: @escaping (TabID, String) -> Void
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.onRename = onRename
        super.init(frame: .zero)
        wantsLayer = true

        docView.wantsLayer = true
        docView.layer?.addSublayer(tracer)

        scrollView.wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView
        scrollView.layer?.mask = edgeFade
        edgeFade.startPoint = CGPoint(x: 0, y: 0.5)
        edgeFade.endPoint = CGPoint(x: 1, y: 0.5)
        addSubview(scrollView)

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: clip)

        tracer.backgroundColor = Theme.current.chrome.accent.nsColor.cgColor
        tracer.cornerRadius = 1
        tracer.anchorPoint = CGPoint(x: 0, y: 0.5)  // position.x is the left edge
        tracer.zPosition = 1  // above the chips regardless of sublayer order
        tracer.isHidden = true  // placed under the active chip on the first render

        // Size the scroll strip to the chip height and center it with the same band nudge as the
        // dock, so the tabs line up with the footer controls by construction (rather than
        // depending on how the scroll/clip views place content vertically).
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Self.chipHeight),
            scrollView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Self.bandNudge),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func render(_ items: [TabBarItem]) {
        lastItems = items
        // A chip per tab id, kept across renders. Rebuilding them took the hovered chip out of the
        // window mid-hover, which tore its tooltip down and re-armed it behind the hover delay: with a
        // title poll every 1.5s the tooltip read as blinking at a steady pace.
        var reusable = Dictionary(uniqueKeysWithValues: chips.map { ($0.id, $0) })
        var next: [Chip] = []
        var activeChip: Chip?
        for item in items {
            let id = item.id
            let chip =
                reusable.removeValue(forKey: id)
                ?? {
                    let fresh = Chip(
                        id: id, attributed: Self.tabLabel(item), index: item.index,
                        onClick: { [weak self] in self?.onSelect(id) },
                        onMiddleClick: { [weak self] in self?.onClose(id) },
                        onDoubleClick: { [weak self] in self?.beginRename(id) })
                    docView.addSubview(fresh)
                    return fresh
                }()
            chip.update(attributed: Self.tabLabel(item), index: item.index)
            next.append(chip)
            if item.isActive { activeChip = chip }
        }
        reusable.values.forEach { $0.removeFromSuperview() }  // tabs that closed
        chips = next
        // A rename dies with its tab; otherwise `layoutChips` re-frames the editor onto the
        // chip's new position, so a re-render mid-edit never strands it over the wrong tab.
        if let renamingID, !items.contains(where: { $0.id == renamingID }) { endRename(commit: false) }
        layoutChips()

        // Slide the tracer to the active tab. Animate only when the active tab actually
        // changed (not on the first render, nor a re-render of the same selection).
        let newActive = items.first(where: \.isActive)?.id
        if let activeChip {
            let selectionChanged = activeTabID != newActive
            moveTracer(to: tracerFrame(for: activeChip), animated: activeTabID != nil && selectionChanged)
            tracer.isHidden = false
            // Reveal the active tab only when the selection actually moves — not on a title-poll
            // re-render, which would otherwise yank the strip back while the user scrolls it. Pad by
            // `fadeWidth` on each side so the revealed tab clears the edge fade instead of sitting
            // under it.
            if selectionChanged {
                activeChip.scrollToVisible(activeChip.bounds.insetBy(dx: -Self.fadeWidth, dy: 0))
            }
        } else {
            tracer.isHidden = true
        }
        activeTabID = newActive
        updateFade()
        // Rebuilding the chips drops the hovered chip (its `viewDidMoveToWindow` tears the tooltip
        // down), and the pointer hasn't moved to re-arm it — so re-establish hover on whatever chip
        // is under the cursor. Only fires on an actual change (`renderTabBar` guards on `changed`).
        refreshHover()
    }

    /// Re-apply the live chrome colors to the already-built bar after a config change — no
    /// relaunch. The tracer's color is baked in once at init and untouched by `render(_:)`, so
    /// it's reset explicitly; the chips/number/labels pick up fresh colors by re-invoking
    /// `render(_:)` with the retained snapshot (its ink colors are computed from
    /// `Theme.current` on every access, not cached).
    func reapplyTheme() {
        tracer.backgroundColor = Theme.current.chrome.accent.nsColor.cgColor
        chips.forEach { $0.reapplyTheme() }
        if let renameEditor { styleRenameEditor(renameEditor) }
        render(lastItems)
    }

    /// Whether a tab is being renamed right now. The window reads this to swallow chords: the key
    /// interceptor runs ahead of the responder chain, so ⌘W would otherwise act while you type.
    var isRenaming: Bool { renamingID != nil }

    /// Open the in-place editor over `id`'s chip, seeded with its current title and all selected.
    /// A no-op if that tab has no chip or another rename is already open.
    func beginRename(_ id: TabID) {
        guard renamingID == nil, let chip = chips.first(where: { $0.id == id }),
            let title = lastItems.first(where: { $0.id == id })?.title
        else { return }

        let field = NSTextField(string: title)
        field.delegate = self
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        styleRenameEditor(field)
        field.frame = chip.frame
        docView.addSubview(field, positioned: .above, relativeTo: chip)

        renameEditor = field
        renamingID = id
        chip.isHidden = true
        window?.makeFirstResponder(field)
        field.applyThemedCaret()  // the editor exists only once the field has focus
        field.currentEditor()?.selectAll(nil)
        field.scrollToVisible(field.bounds.insetBy(dx: -Self.fadeWidth, dy: 0))
    }

    /// Tear the editor down, reporting the trimmed value when `commit`. Re-entrant-safe: pulling
    /// the field out of the tree fires `controlTextDidEndEditing`, which lands back here.
    private func endRename(commit: Bool) {
        guard !isEndingRename, let field = renameEditor, let id = renamingID else { return }
        isEndingRename = true
        defer { isEndingRename = false }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        renameEditor = nil
        renamingID = nil
        chips.first(where: { $0.id == id })?.isHidden = false
        if field.currentEditor() != nil { window?.makeFirstResponder(nil) }
        field.removeFromSuperview()
        if commit { onRename(id, value) }
    }

    /// The editor reads as the chip becoming editable: same font, the active fill behind it.
    private func styleRenameEditor(_ field: NSTextField) {
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        field.textColor = Theme.current.chrome.ink(.normal)
        field.layer?.backgroundColor = Theme.current.chrome.fill(.active).cgColor
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): endRename(commit: true)
        case #selector(NSResponder.cancelOperation(_:)): endRename(commit: false)
        default: return false
        }
        return true
    }

    /// Clicking away commits, matching every other in-place rename on the platform.
    func controlTextDidEndEditing(_ obj: Notification) {
        endRename(commit: true)
    }

    /// Test hook: the chip views currently in the bar.
    var chipsForTesting: [NSView] { chips }

    /// Test hook: the open rename editor, so a test drives the real field rather than the state.
    var renameEditorForTesting: NSTextField? { renameEditor }

    /// Test hook: each chip's rendered label. Chips persist across renders now, so a
    /// re-render has to be asserted on what the chip draws rather than on a new instance appearing.
    var chipLabelsForTesting: [NSAttributedString] { chips.map(\.attributedLabelForTesting) }

    /// Test hook: the tracer underline's current color.
    var tracerColorForTesting: NSColor? { tracer.backgroundColor.flatMap { NSColor(cgColor: $0) } }

    /// Test hook: whether the trailing-edge overflow fade is currently active.
    var isOverflowFadedForTesting: Bool { hasRightOverflow }

    /// Test hook: whether the leading-edge overflow fade is currently active.
    var isLeadingFadedForTesting: Bool { hasLeftOverflow }

    /// Test hook: the rendered label string (number prefix + title) for an item.
    static func tabLabelStringForTesting(_ item: TabBarItem) -> String { tabLabel(item).string }

    /// Test hook: each chip's tooltip title + resolved keycap, in bar order — the ⌘N
    /// shortcut moved off the inline label onto the hover tooltip.
    var chipTooltipsForTesting: [(label: String, shortcut: String?)] {
        chips.map { ($0.tooltipLabelForTesting, $0.tooltipShortcutForTesting) }
    }

    /// Test hook: scroll the strip to a horizontal offset, as a trackpad drag would.
    func scrollToForTesting(x: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: CGPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(clip)
        updateFade()
    }

    override func layout() {
        super.layout()
        // Re-frame the chips + content width so the strip tracks window resizes, then clamp any
        // stale scroll offset once the bar is wide enough that the tabs fit again.
        layoutChips()
        clampScrollIfContentFits()

        // The mask covers the scroll view in its own (window-fixed) space; its ramp stops are
        // geometry, so update frame + locations without animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.frame = scrollView.bounds
        let w = scrollView.bounds.width
        let f = w > 2 * Self.fadeWidth ? Double(Self.fadeWidth / w) : 0
        edgeFade.locations = [0, NSNumber(value: f), NSNumber(value: 1 - f), 1]
        CATransaction.commit()
        updateFade()
    }

    /// Lay the chips out left-to-right with the leading inset and fixed spacing, then size the
    /// document view to hug the last chip (no trailing pad, so the final tab never reads as
    /// phantom overflow that would keep the fade over it).
    private func layoutChips() {
        // The scroll strip is already the chip height and centered with the band nudge, so chips
        // just fill it — no per-chip nudge here.
        let h = scrollView.contentView.bounds.height > 0 ? scrollView.contentView.bounds.height : Self.chipHeight
        let chipY = (h - Self.chipHeight) / 2
        var x = Self.leadingInset
        for chip in chips {
            let width = chip.fittingWidth
            chip.frame = CGRect(x: x, y: chipY, width: width, height: Self.chipHeight)
            x += width + Self.chipSpacing
        }
        let contentWidth = chips.isEmpty ? 0 : x - Self.chipSpacing
        docView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: h)
        if let renameEditor, let chip = chips.first(where: { $0.id == renamingID }) {
            renameEditor.frame = chip.frame
        }
    }

    /// When the bar grows enough that all tabs fit, snap any leftover scroll offset back to the
    /// start so there's no empty gutter and both edges read as un-faded.
    private func clampScrollIfContentFits() {
        let clip = scrollView.contentView
        if docView.frame.width <= clip.bounds.width, clip.bounds.origin.x > 0 {
            clip.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    @objc private func clipBoundsChanged() {
        updateFade()
        refreshHover()
    }

    /// Recompute hover from the actual mouse position. Per-chip tracking areas miss `mouseExited`
    /// when chips slide under a stationary cursor during a scroll, leaving several stuck hovered;
    /// this sets exactly the chip under the pointer (if any, and only while this is the key window).
    private func refreshHover() {
        guard let window, window.isKeyWindow else {
            chips.forEach { $0.setHover(false) }
            return
        }
        let mouse = window.mouseLocationOutsideOfEventStream
        let visible = scrollView.contentView.documentVisibleRect
        for chip in chips {
            let underPointer = chip.frame.intersects(visible) && chip.convert(chip.bounds, to: nil).contains(mouse)
            chip.setHover(underPointer)
        }
    }

    /// Whether any chip content sits off-screen to the right of the visible strip.
    private var hasRightOverflow: Bool {
        let clip = scrollView.contentView
        let visibleMaxX = clip.bounds.origin.x + clip.bounds.width
        return docView.frame.width - visibleMaxX > 0.5
    }

    /// Whether the strip is scrolled far enough right that content is hidden off the left edge.
    private var hasLeftOverflow: Bool {
        scrollView.contentView.bounds.origin.x > 0.5
    }

    /// Fade each edge only when tabs overflow past it; an edge with nothing beyond stays fully
    /// opaque so nothing dissolves there. Alpha-only ramp — theme-independent (see `edgeFade`).
    private func updateFade() {
        let opaque = CGColor(gray: 1, alpha: 1)
        let clear = CGColor(gray: 1, alpha: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.colors = [
            hasLeftOverflow ? clear : opaque, opaque, opaque, hasRightOverflow ? clear : opaque,
        ]
        CATransaction.commit()
    }

    /// The 2pt underline frame under `chip` (its label inset 9pt each side), in the scrolling
    /// content's coordinates so the tracer scrolls with the chips. Pinned to the bar's bottom
    /// band rather than the chip's own (nudged) origin so it reads as a consistent underline.
    private func tracerFrame(for chip: NSView) -> CGRect {
        CGRect(x: chip.frame.minX + 9, y: 0, width: chip.frame.width - 18, height: 2)
    }

    /// Set the tracer's frame with no implicit animation (an owned layer would otherwise
    /// animate every property change on its own default 0.25s curve).
    private func setTracerFrame(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tracer.frame = frame
        CATransaction.commit()
    }

    private func moveTracer(to target: CGRect, animated: Bool) {
        guard animated, !Motion.isReduceMotionEnabled() else {
            setTracerFrame(target)
            return
        }
        let start = tracer.presentation()?.frame ?? tracer.frame  // live frame, mid-slide if interrupted
        setTracerFrame(target)  // model = final resting frame

        // The stretch, expressed as the left edge (position.x, since the anchor's x is 0)
        // and the width: the leading edge reaches the target while the trailing edge holds,
        // then the trailing edge eases in and the width closes — so it only reaches toward
        // the target, never growing symmetrically about the center.
        let movingRight = target.midX >= start.midX
        let leftValues: [CGFloat] =
            movingRight
            ? [start.minX, start.minX, target.minX] : [start.minX, target.minX, target.minX]
        let widthValues: [CGFloat] =
            movingRight
            ? [start.width, target.maxX - start.minX, target.width]
            : [start.width, start.maxX - target.minX, target.width]

        let left = CAKeyframeAnimation(keyPath: "position.x")
        left.values = leftValues.map { $0 as NSNumber }
        let width = CAKeyframeAnimation(keyPath: "bounds.size.width")
        width.values = widthValues.map { $0 as NSNumber }
        for anim in [left, width] {
            anim.keyTimes = [0, 0.5, 1]
            anim.duration = Self.tracerDuration
            anim.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),  // leading edge darts toward the target
                CAMediaTimingFunction(name: .easeInEaseOut),  // trailing edge eases in
            ]
        }
        tracer.add(left, forKey: "tracer.left")
        tracer.add(width, forKey: "tracer.width")
    }

    private static func tabLabel(_ item: TabBarItem) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let ink = item.isActive ? activeInk : idleInk
        let numberColor: NSColor
        switch item.attentionState {
        // The number carries its tab's own weight, not a weight of its own: full bright on the
        // active tab, resting on the others. A separate value for it made the two halves of one
        // label read as two things.
        case .idle: numberColor = ink
        case .completed: numberColor = Theme.current.chrome.positive.nsColor
        case .waiting: numberColor = Theme.current.chrome.attention.nsColor
        }
        // A bare number — the ⌘N binding for tabs 1–9 lives in the hover tooltip now, not inline.
        // The prefix shares `numberColor`, so it recolors with the tab attention state.
        let prefix = "\(item.index) "
        let s = NSMutableAttributedString(
            string: prefix,
            attributes: [.font: font, .foregroundColor: numberColor])
        s.append(
            NSAttributedString(
                string: item.title,
                attributes: [.font: font, .foregroundColor: ink, .kern: 0.4]))
        return s
    }

    /// A rounded box holding a centered label. The box background appears on hover
    /// only; the active tab is marked by the shared tracer underline. Used for tabs so they
    /// share hover feel and stay vertically aligned.
    private final class Chip: NSView {
        /// The tab this chip stands for, so `render` can hand a chip back to the same tab instead of
        /// building a new one.
        let id: TabID
        /// The tab's 1-based position, which the tooltip's keycap reads at hover time. A `var` because
        /// closing a tab renumbers the ones after it, and the chip outlives that now.
        private var tabIndex: Int
        private let onClick: () -> Void
        private let onMiddleClick: (() -> Void)?
        private let onDoubleClick: (() -> Void)?
        private var isHovered = false
        private let label: NSTextField
        /// The hover-tooltip wiring — a branded `ChromeTooltip` (the same one the footer dock buttons
        /// use), evaluated at hover time so its keybind tracks the live keymap. Shared with
        /// `IconButton`. `lazy` so the resolver can read this chip's live index.
        private lazy var tooltip = TooltipHost(label: "Focus tab") { [weak self] in
            // Tabs past ⌘9 have no binding, so the keycap is omitted rather than invented.
            guard let self, self.tabIndex <= 9 else { return nil }
            return CommandCatalog.spec(for: .selectTab(self.tabIndex)).shortcut
        }

        /// The width this chip wants: its label plus the 9pt inset on each side. Read from the
        /// label's intrinsic size (not `fittingSize`) so it's independent of the frame the parent
        /// assigns during manual layout.
        var fittingWidth: CGFloat { label.intrinsicContentSize.width + 18 }

        var attributedLabelForTesting: NSAttributedString { label.attributedStringValue }

        /// Test hooks for the tooltip content, mirroring `IconButton`.
        var tooltipLabelForTesting: String { tooltip.label }
        var tooltipShortcutForTesting: String? { tooltip.shortcutForTesting }

        init(
            id: TabID, attributed: NSAttributedString, index: Int,
            onClick: @escaping () -> Void, onMiddleClick: (() -> Void)?,
            onDoubleClick: (() -> Void)?
        ) {
            self.id = id
            self.tabIndex = index
            self.onClick = onClick
            self.onMiddleClick = onMiddleClick
            self.onDoubleClick = onDoubleClick
            label = NSTextField(labelWithAttributedString: attributed)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6

            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Re-render this chip for its tab's current title, number, and active state.
        func update(attributed: NSAttributedString, index: Int) {
            tabIndex = index
            guard label.attributedStringValue != attributed else { return }
            label.attributedStringValue = attributed
            needsLayout = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) { setHover(true) }
        override func mouseExited(with event: NSEvent) { setHover(false) }

        /// Drop the tooltip if this chip leaves the window (a title-poll re-render rebuilds the
        /// chips without firing `mouseExited`, so the old chip's tooltip would otherwise linger).
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { tooltip.hide(from: self) }
        }

        /// Externally-driven hover (from the bar's scroll-time recompute), a no-op when unchanged.
        /// Also drives the tooltip, so a chip that slides under a stationary cursor during a scroll
        /// gets one too (its per-chip tracking area misses that `mouseEntered`).
        func setHover(_ on: Bool) {
            guard isHovered != on else { return }
            isHovered = on
            updateBackground()
            if on { tooltip.show(from: self) } else { tooltip.hide(from: self) }
        }
        override func mouseDown(with event: NSEvent) {
            tooltip.hide(from: self)  // a click dismisses the tooltip
            // The pair arrives as two events: the first selects the tab, the second renames it.
            if event.clickCount == 2 { onDoubleClick?() } else { onClick() }
        }
        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { onMiddleClick?() }  // middle-click closes
        }

        /// Re-apply the hover wash from the live theme. `setHover` returns early when the state is
        /// unchanged, so a chip hovered across a theme swap would otherwise keep the old ink until the
        /// pointer left it. Only the theme path needs this: a re-render doesn't change the color.
        func reapplyTheme() {
            updateBackground()
        }

        private func updateBackground() {
            guard let layer else { return }
            Motion.ease(
                layer, keyPath: "backgroundColor",
                to: (isHovered ? Theme.current.chrome.fill(.hover) : .clear).cgColor)
        }
    }
}
