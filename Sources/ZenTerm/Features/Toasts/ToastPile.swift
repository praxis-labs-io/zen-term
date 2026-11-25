import AppKit

// Every toast and card, folded behind one in front by default and unfolded into a list on a click.
final class ToastPile: NSView {
    var onUnfoldChange: ((Bool) -> Void)?
    private(set) var isUnfolded = false
    private(set) var cards: [NSView] = []
    private var choices: Set<ObjectIdentifier> = []
    private var leaving: Set<ObjectIdentifier> = []
    private let plates = (0..<ToastPile.plateOpacity.count).map { _ in Plate() }
    private let showLess = AppButton(title: "Show Less", variant: .secondary)
    private var arrangement: [NSLayoutConstraint] = []
    private var clickMonitor: Any?
    private let foldsOnClickOutside: Bool

    // A fixed alpha mask: each folded card behind is fainter, and no chrome token names a recession step.
    private static let plateOpacity: [Float] = [0.75, 0.45]
    private static let plateDrop = ChromeMetrics.Spacing.s12
    private static let plateInset = ChromeMetrics.Spacing.s10
    private static let listGap = ChromeMetrics.Spacing.s8

    // The Component Gallery shows an unfolded stack that a click elsewhere in the gallery leaves open.
    init(foldsOnClickOutside: Bool = true) {
        self.foldsOnClickOutside = foldsOnClickOutside
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let snug = widthAnchor.constraint(equalToConstant: 0)
        snug.priority = .defaultLow
        snug.isActive = true
        for view in plates + [showLess] {
            view.wantsLayer = true
            view.layer?.opacity = 0
            view.isHidden = true
            addSubview(view)
            view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
        }
        showLess.onTap = { [weak self] in self?.fold() }
        relayout(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    deinit {
        clickMonitor.map(NSEvent.removeMonitor)
    }

    private var settled: [NSView] { cards.filter { !leaving.contains(ObjectIdentifier($0)) } }

    var front: NSView? {
        let shown = settled
        return shown.last { choices.contains(ObjectIdentifier($0)) } ?? shown.last
    }

    // Front first, then newest to oldest: the order the unfolded list reads in.
    private var ordered: [NSView] {
        guard let front else { return [] }
        return [front] + settled.reversed().filter { $0 !== front }
    }

    // `holdsChoice` keeps the card in front of anything newer, so a pending choice is never folded away.
    func add(_ card: NSView, holdsChoice: Bool = false) {
        cards.append(card)
        if holdsChoice { choices.insert(ObjectIdentifier(card)) }
        card.wantsLayer = true
        addSubview(card, positioned: .below, relativeTo: showLess)
        NSLayoutConstraint.activate([
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
        if card === front { raise(card) }
        relayout(animated: true, arriving: card)
    }

    func release(_ card: NSView) {
        guard cards.contains(where: { $0 === card }) else { return }
        leaving.insert(ObjectIdentifier(card))
        if settled.count <= 1 { setUnfolded(false) }
        front.map(raise)
        raise(card)
        relayout(animated: true)
    }

    func bringForward(_ card: NSView) {
        guard let index = cards.firstIndex(where: { $0 === card }), !leaving.contains(ObjectIdentifier(card))
        else { return }
        cards.append(cards.remove(at: index))
        front.map(raise)
        relayout(animated: true)
    }

    func remove(_ card: NSView) {
        let id = ObjectIdentifier(card)
        cards.removeAll { $0 === card }
        choices.remove(id)
        leaving.remove(id)
        card.removeFromSuperview()
        relayout(animated: true)
    }

    func unfold() {
        guard !isUnfolded, settled.count > 1 else { return }
        setUnfolded(true)
        relayout(animated: true)
    }

    func fold() {
        guard isUnfolded else { return }
        setUnfolded(false)
        relayout(animated: true)
    }

    private func setUnfolded(_ unfolded: Bool) {
        guard unfolded != isUnfolded else { return }
        isUnfolded = unfolded
        unfolded && foldsOnClickOutside ? watchForClicksOutside() : stopWatchingClicks()
        onUnfoldChange?(unfolded)
    }

    private func raise(_ card: NSView) {
        guard card.superview === self else { return }
        addSubview(card, positioned: .below, relativeTo: showLess)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isUnfolded, settled.count > 1, let front else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard local.x >= front.frame.minX, local.x <= front.frame.maxX, bounds.contains(local) else { return nil }
        if let hit = super.hitTest(point), Self.isControl(hit, within: front) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        unfold()
    }

    private static func isControl(_ view: NSView, within card: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current, candidate !== card {
            if candidate is NSButton || candidate is ControlView { return true }
            current = candidate.superview
        }
        return false
    }

    private func watchForClicksOutside() {
        stopWatchingClicks()
        let presses: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: presses) { [weak self] event in
            self?.clickPassingThrough(event) ?? event
        }
    }

    private func stopWatchingClicks() {
        clickMonitor.map(NSEvent.removeMonitor)
        clickMonitor = nil
    }

    // Returns the event untouched, so the click that folds the pile still lands where it was aimed.
    private func clickPassingThrough(_ event: NSEvent) -> NSEvent {
        let point = superview?.convert(event.locationInWindow, from: nil)
        if event.window !== window || !(point.map(frame.contains) ?? false) { fold() }
        return event
    }

    private func relayout(animated: Bool, arriving: NSView? = nil) {
        superview?.layoutSubtreeIfNeeded()
        NSLayoutConstraint.deactivate(arrangement)
        arrangement = isUnfolded ? listArrangement() : foldedArrangement()
        NSLayoutConstraint.activate(arrangement)
        isHidden = cards.isEmpty
        fadeToTargets(sparing: arriving)
        if let arriving { settle(arriving) }
        guard animated, !Motion.isReduceMotionEnabled() else {
            superview?.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.pageSlideDuration
            context.timingFunction = Motion.landingTiming
            context.allowsImplicitAnimation = true
            superview?.layoutSubtreeIfNeeded()
        }
    }

    // An arriving card starts where it lands, so only its own entrance moves it.
    private func settle(_ arriving: NSView) {
        guard isShowing(arriving) else {
            arriving.layer?.opacity = 0
            arriving.isHidden = true
            return
        }
        let size = arriving.fittingSize
        let top = isUnfolded && arriving !== front ? front.map { $0.frame.maxY + Self.listGap } ?? 0 : 0
        arriving.frame = NSRect(x: bounds.width - size.width, y: top, width: size.width, height: size.height)
        arriving.layoutSubtreeIfNeeded()
    }

    func isShowing(_ card: NSView) -> Bool { isUnfolded || card === front }

    private func pinLeaving() -> [NSLayoutConstraint] {
        cards.filter { leaving.contains(ObjectIdentifier($0)) }.map {
            $0.topAnchor.constraint(equalTo: topAnchor, constant: $0.frame.minY)
        }
    }

    private func listArrangement() -> [NSLayoutConstraint] {
        var constraints = pinLeaving()
        var above = topAnchor
        var gap: CGFloat = 0
        for card in ordered {
            constraints.append(card.topAnchor.constraint(equalTo: above, constant: gap))
            above = card.bottomAnchor
            gap = Self.listGap
        }
        constraints += [
            showLess.topAnchor.constraint(equalTo: above, constant: gap),
            showLess.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomAnchor.constraint(equalTo: showLess.bottomAnchor),
        ]
        constraints += plates.flatMap { plateConstraints($0, step: 0) }
        return constraints
    }

    private func foldedArrangement() -> [NSLayoutConstraint] {
        var constraints = pinLeaving()
        constraints += [
            showLess.topAnchor.constraint(equalTo: topAnchor),
            showLess.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        guard let front else {
            constraints.append(heightAnchor.constraint(equalToConstant: 0))
            constraints += plates.flatMap { plateConstraints($0, step: 0) }
            return constraints
        }
        constraints += settled.map { $0.topAnchor.constraint(equalTo: topAnchor) }
        constraints.append(
            bottomAnchor.constraint(equalTo: front.bottomAnchor, constant: Self.plateDrop * CGFloat(foldedDepth)))
        constraints += plates.enumerated().flatMap { plateConstraints($1, step: CGFloat($0 + 1)) }
        return constraints
    }

    private var foldedDepth: Int { min(max(settled.count - 1, 0), plates.count) }

    private func plateConstraints(_ plate: Plate, step: CGFloat) -> [NSLayoutConstraint] {
        guard let front else {
            return [
                plate.topAnchor.constraint(equalTo: topAnchor),
                plate.leadingAnchor.constraint(equalTo: leadingAnchor),
                plate.widthAnchor.constraint(equalToConstant: 0),
                plate.heightAnchor.constraint(equalToConstant: 0),
            ]
        }
        let inset = Self.plateInset * step
        return [
            plate.topAnchor.constraint(equalTo: front.topAnchor, constant: Self.plateDrop * step),
            plate.heightAnchor.constraint(equalTo: front.heightAnchor),
            plate.leadingAnchor.constraint(equalTo: front.leadingAnchor, constant: inset),
            plate.trailingAnchor.constraint(equalTo: front.trailingAnchor, constant: -inset),
        ]
    }

    private func targetOpacity(of view: NSView) -> Float? {
        if view === showLess { return isUnfolded ? 1 : 0 }
        if let index = plates.firstIndex(where: { $0 === view }) {
            return !isUnfolded && index < foldedDepth ? Self.plateOpacity[index] : 0
        }
        guard !leaving.contains(ObjectIdentifier(view)) else { return nil }
        return isUnfolded || view === front ? 1 : 0
    }

    private func fadeToTargets(sparing arriving: NSView?) {
        for view in plates + cards + [showLess] where view !== arriving {
            guard let target = targetOpacity(of: view), let layer = view.layer else { continue }
            if target > 0 { view.isHidden = false }
            guard layer.opacity != target else { continue }
            Motion.fade(view, to: target) { [weak self, weak view] in
                guard let self, let view, view.superview === self, view.layer?.opacity == 0,
                    self.targetOpacity(of: view) == 0
                else { return }
                view.isHidden = true
            }
        }
    }

    func clickForTesting(_ event: NSEvent) -> NSEvent { clickPassingThrough(event) }
    func opacityForTesting(_ card: NSView) -> Float? { card.isHidden ? 0 : card.layer?.opacity }
    var plateOpacityForTesting: [Float] { plates.map { $0.isHidden ? 0 : $0.layer?.opacity ?? 0 } }
    var showLessForTesting: AppButton { showLess }

    private final class Plate: ShadowCardView, ThemeReapplying {
        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            CardChrome.apply(to: self, tier: .float)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func reapplyTheme() { CardChrome.reapplyTheme(to: self, tier: .float) }
    }
}
