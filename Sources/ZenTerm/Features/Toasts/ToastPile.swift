import AppKit

// Every toast and card, folded behind one in front by default and unfolded into a list on a click.
final class ToastPile: NSView {
    var onUnfoldChange: ((Bool) -> Void)?
    private(set) var isUnfolded = false
    private(set) var cards: [NSView] = []
    private var leaving: Set<ObjectIdentifier> = []
    private let plates = ChromeTheme.toastRecession.map(Plate.init)
    var onClear: (() -> Void)?
    private let listToggle = AppButton(title: ToastPile.showMore, variant: .quietLink)
    private let clear = AppButton(title: "Clear", variant: .quietLink)
    // Mounted behind the cards: under the folded stack on hover, at the end of the list once unfolded.
    private let footer: NSStackView
    private var isHovering = false
    private var restingPoses: [ObjectIdentifier: CATransform3D] = [:]
    private var arrangement: [NSLayoutConstraint] = []
    private var clickMonitor: Any?
    private let foldsOnClickOutside: Bool

    private static let plateDrop = ChromeMetrics.Spacing.s12
    private static let plateInset = ChromeMetrics.Spacing.s10
    private static let listGap = ChromeMetrics.Spacing.s8
    private static let showMore = "Show More"
    private static let showLess = "Show Less"

    // The Component Gallery shows an unfolded stack that a click elsewhere in the gallery leaves open.
    init(foldsOnClickOutside: Bool = true) {
        self.foldsOnClickOutside = foldsOnClickOutside
        footer = NSStackView(views: [clear, listToggle])
        super.init(frame: .zero)
        footer.orientation = .horizontal
        footer.spacing = ChromeMetrics.Spacing.s12
        footer.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        let snug = widthAnchor.constraint(equalToConstant: 0)
        snug.priority = .defaultLow
        snug.isActive = true
        for view in [footer] + plates.reversed() {
            view.wantsLayer = true
            view.layer?.opacity = 0
            view.isHidden = true
            addSubview(view)
            view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
        }
        clear.onTap = { [weak self] in self?.onClear?() }
        listToggle.onTap = { [weak self] in
            guard let self else { return }
            self.isUnfolded ? self.fold() : self.unfold()
        }
        relayout(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    deinit {
        clickMonitor.map(NSEvent.removeMonitor)
    }

    private var settled: [NSView] { cards.filter { !leaving.contains(ObjectIdentifier($0)) } }

    var front: NSView? { settled.last }

    // Front first, then newest to oldest: the order the unfolded list reads in.
    private var ordered: [NSView] {
        guard let front else { return [] }
        return [front] + settled.reversed().filter { $0 !== front }
    }

    func add(_ card: NSView) {
        cards.append(card)
        card.wantsLayer = true
        addSubview(card)
        NSLayoutConstraint.activate([
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
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
        leaving.remove(id)
        restingPoses[id] = nil
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
        listToggle.setTitle(unfolded ? Self.showLess : Self.showMore)
        unfolded && foldsOnClickOutside ? watchForClicksOutside() : stopWatchingClicks()
        onUnfoldChange?(unfolded)
    }

    private func raise(_ card: NSView) {
        guard card.superview === self else { return }
        addSubview(card)
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        refreshHover()
    }

    // A stack that folds out from under a still pointer, or rebuilds its tracking area, never gets `mouseExited`.
    private func refreshHover() {
        guard isHovering, !pointerIsInside else { return }
        setHovering(false)
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }

    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        fadeToTargets(sparing: nil)
    }

    override func resetCursorRects() {
        guard !isUnfolded, foldedDepth > 0 else { return }
        addCursorRect(bounds, cursor: .pointingHand)
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
        if event.window !== window || !visibleRect.contains(convert(event.locationInWindow, from: nil)) { fold() }
        return event
    }

    private func relayout(animated: Bool, arriving: NSView? = nil) {
        (window?.contentView ?? superview)?.layoutSubtreeIfNeeded()
        let wasEmpty = isHidden
        NSLayoutConstraint.deactivate(arrangement)
        arrangement = isUnfolded ? listArrangement() : foldedArrangement()
        NSLayoutConstraint.activate(arrangement)
        isHidden = cards.isEmpty
        window?.invalidateCursorRects(for: self)
        fadeToTargets(sparing: arriving)
        if let arriving { settle(arriving) }
        defer { refreshHover() }
        guard animated, !wasEmpty, !Motion.isReduceMotionEnabled() else {
            (window?.contentView ?? superview)?.layoutSubtreeIfNeeded()
            restack(sparing: arriving, animated: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.pageSlideDuration
            context.timingFunction = Motion.landingTiming
            context.allowsImplicitAnimation = true
            (window?.contentView ?? superview)?.layoutSubtreeIfNeeded()
        }
        restack(sparing: arriving, animated: true)
        if let arriving, arriving === front, !isUnfolded { pushPlatesBack() }
    }

    // A full stack shows no new plate, so each plate drops back from the one in front of it on every arrival.
    private func pushPlatesBack() {
        guard let front else { return }
        for (index, plate) in plates.enumerated() where index < foldedDepth {
            guard let layer = plate.layer else { continue }
            let ahead = front.frame.insetBy(dx: Self.plateInset * CGFloat(index), dy: 0)
                .offsetBy(dx: 0, dy: Self.plateDrop * CGFloat(index))
            Motion.morph(layer, from: Self.pose(of: plate.frame, onto: ahead), to: CATransform3DIdentity)
        }
    }

    private static func pose(of frame: CGRect, onto target: CGRect) -> CATransform3D {
        let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        var pose = CATransform3DMakeTranslation(target.midX - frame.midX, target.midY - frame.midY, 0)
        pose = CATransform3DTranslate(pose, center.x, center.y, 0)
        pose = CATransform3DScale(pose, target.width / frame.width, 1, 1)
        return CATransform3DTranslate(pose, -center.x, -center.y, 0)
    }

    // Each folded card shrinks onto its plate, so unfolding grows it out of the stack and folding sinks it back.
    private func restack(sparing arriving: NSView?, animated: Bool) {
        for card in cards where !leaving.contains(ObjectIdentifier(card)) {
            let id = ObjectIdentifier(card)
            let target = restingTransform(of: card)
            let previous = restingPoses[id] ?? CATransform3DIdentity
            restingPoses[id] = target
            guard animated, card !== arriving, let layer = card.layer, !CATransform3DEqualToTransform(previous, target)
            else { continue }
            Motion.morph(layer, from: previous, to: target)
        }
    }

    private func restingTransform(of card: NSView) -> CATransform3D {
        guard !isUnfolded, let front, card !== front, foldedDepth > 0, card.bounds.width > 0,
            let depth = ordered.firstIndex(where: { $0 === card })
        else { return CATransform3DIdentity }
        let step = CGFloat(min(depth, foldedDepth))
        let card = card.bounds.size
        let plate = NSSize(width: front.bounds.width - 2 * Self.plateInset * step, height: front.bounds.height)
        let scale = plate.width / card.width
        let shift = CGVector(
            dx: (card.width - front.bounds.width) / 2,
            dy: Self.plateDrop * step + plate.height - (card.height + card.height * scale) / 2)
        return CATransform3DConcat(
            Motion.centeredScale(scale, in: CGRect(origin: .zero, size: card)),
            CATransform3DMakeTranslation(shift.dx, shift.dy, 0))
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
            footer.topAnchor.constraint(equalTo: above, constant: gap),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ]
        constraints += plates.flatMap { plateConstraints($0, step: 0) }
        return constraints
    }

    private func foldedArrangement() -> [NSLayoutConstraint] {
        var constraints = pinLeaving()
        constraints.append(footer.trailingAnchor.constraint(equalTo: trailingAnchor))
        guard let front else {
            constraints.append(footer.topAnchor.constraint(equalTo: topAnchor))
            constraints.append(heightAnchor.constraint(equalToConstant: 0))
            constraints += plates.flatMap { plateConstraints($0, step: 0) }
            return constraints
        }
        constraints += settled.map { $0.topAnchor.constraint(equalTo: topAnchor) }
        let stackBottom = Self.plateDrop * CGFloat(foldedDepth)
        if foldedDepth > 0 {
            constraints += [
                footer.topAnchor.constraint(equalTo: front.bottomAnchor, constant: stackBottom + Self.listGap),
                bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            ]
        } else {
            constraints += [
                footer.topAnchor.constraint(equalTo: topAnchor),
                bottomAnchor.constraint(equalTo: front.bottomAnchor),
            ]
        }
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
        if view === footer { return isUnfolded || (isHovering && foldedDepth > 0) ? 1 : 0 }
        if let index = plates.firstIndex(where: { $0 === view }) {
            return !isUnfolded && index < foldedDepth ? 1 : 0
        }
        guard !leaving.contains(ObjectIdentifier(view)) else { return nil }
        return isUnfolded || view === front ? 1 : 0
    }

    private func fadeToTargets(sparing arriving: NSView?) {
        for view in plates + cards + [footer] where view !== arriving {
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
    var listToggleForTesting: AppButton { listToggle }
    var clearForTesting: AppButton { clear }
    var footerOpacityForTesting: Float { opacityForTesting(footer) ?? 0 }
    func restingPoseForTesting(_ card: NSView) -> CATransform3D { restingTransform(of: card) }
    var plateLayerFramesForTesting: [CGRect] { plates.compactMap { $0.layer?.frame } }
    var plateLayersForTesting: [CALayer] { plates.compactMap(\.layer) }
    var plateRecessionForTesting: [CGFloat] { plates.map(\.recessionForTesting) }
    var isStackedBackToFrontForTesting: Bool {
        let backdrop = ([footer] + plates.reversed()).compactMap { subviews.firstIndex(of: $0) }
        let front = cards.compactMap { subviews.firstIndex(of: $0) }
        return backdrop == backdrop.sorted() && (backdrop.last ?? 0) < (front.min() ?? .max)
    }

    // Opaque, so a folded card never shows the one behind it; the recession veil fades it instead.
    private final class Plate: ShadowCardView, ThemeReapplying {
        private let recession: CGFloat
        private let veil = NSView()

        init(recession: CGFloat) {
            self.recession = recession
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            CardChrome.apply(to: self, tier: .float)
            veil.wantsLayer = true
            veil.translatesAutoresizingMaskIntoConstraints = false
            veil.layer?.cornerRadius = ChromeMetrics.Radius.surface
            addSubview(veil)
            NSLayoutConstraint.activate([
                veil.leadingAnchor.constraint(equalTo: leadingAnchor),
                veil.trailingAnchor.constraint(equalTo: trailingAnchor),
                veil.topAnchor.constraint(equalTo: topAnchor),
                veil.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            reapplyTheme()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        var recessionForTesting: CGFloat { veil.layer?.backgroundColor?.alpha ?? 0 }

        func reapplyTheme() {
            CardChrome.reapplyTheme(to: self, tier: .float)
            veil.layer?.backgroundColor =
                Theme.current.chrome.background.nsColor.withAlphaComponent(recession).cgColor
        }
    }
}
