import AppKit

/// One motion system for the whole chrome. All timing lives here so every animation feels
/// like the same system. Overlay cards use a snappy spring with a slight overshoot; the
/// focus halo and button/chip tints use a smooth ease.
///
/// Honors Reduce Motion globally — when on, every primitive applies its final state
/// instantly and runs the completion **synchronously**, so callers that sequence work in
/// the completion behave identically.
///
/// Chrome-only (AppKit + Core Animation). Never touches a terminal backend.
enum Motion {
    // MARK: - Timing

    /// Structural spring — panels/cards appearing, new pane/tab. ~0.7 damping ratio
    /// (gentle overshoot), ~0.16s settle. Snappy over smooth.
    enum Spring {
        static let mass: CGFloat = 1
        static let stiffness: CGFloat = 1400
        static let damping: CGFloat = 48

        static func make(keyPath: String) -> CASpringAnimation {
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = mass
            spring.stiffness = stiffness
            spring.damping = damping
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            return spring
        }
    }

    /// Halo / tint ease — a smooth crossfade as focus moves, still quick enough to keep up
    /// with ⌘hjkl nav.
    static let haloDuration: CFTimeInterval = 0.18
    /// Canvas page-slide on a tab switch — decelerating hard so it lands.
    static let pageSlideDuration: CFTimeInterval = 0.28
    /// New-tab canvas fade-in.
    static let fadeDuration: CFTimeInterval = 0.18
    /// The opacity ramp of a scale-fade entrance. Kept short and decoupled from the
    /// spring settle so the card *reads* as present fast — the dominant snappiness cue —
    /// while the scale settles under the spring behind it.
    static let entranceFadeDuration: CFTimeInterval = 0.11
    /// Scale a card rests at while faded out during a scale-fade entrance.
    static let entranceScale: CGFloat = 0.97

    // MARK: - Reduce Motion

    /// Overridable so tests can exercise both paths; production reads the system setting.
    static var isReduceMotionEnabled: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Primitives

    /// Opacity 0↔1 + scale `entranceScale`↔1.0 about the view's center. Float cards, a
    /// new pane, a new tab. `appearing` false runs it in reverse (caller removes the view
    /// in `completion`).
    static func springScaleFade(_ view: NSView, appearing: Bool, completion: (() -> Void)? = nil) {
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        guard let layer = view.layer else { completion?(); return }

        let shownTransform = CATransform3DIdentity
        let hiddenTransform = centeredScale(entranceScale, in: layer.bounds)
        let targetTransform = appearing ? shownTransform : hiddenTransform
        let targetOpacity: Float = appearing ? 1 : 0

        if isReduceMotionEnabled() {
            layer.transform = shownTransform
            layer.opacity = targetOpacity
            completion?()
            return
        }

        // Start from the explicit opposite state (hidden when appearing, shown when
        // disappearing) — a freshly-presented card already sits at the shown state, so
        // reading its current value would animate from→to as a no-op. Only when a motion
        // animation is already in flight do we pick up its mid-flight presentation value,
        // so a rapid open→close stays smooth.
        let interrupting = layer.animation(forKey: "motion.transform") != nil
        let fromTransform: CATransform3D
        let fromOpacity: Float
        if interrupting, let p = layer.presentation() {
            fromTransform = p.transform
            fromOpacity = p.opacity
        } else {
            fromTransform = appearing ? hiddenTransform : shownTransform
            fromOpacity = appearing ? 0 : 1
        }
        layer.transform = targetTransform
        layer.opacity = targetOpacity

        let spring = Spring.make(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: fromTransform)
        spring.toValue = NSValue(caTransform3D: targetTransform)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = targetOpacity
        fade.duration = entranceFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        run(completion: completion) {
            layer.add(spring, forKey: "motion.transform")
            layer.add(fade, forKey: "motion.opacity")
        }
    }

    /// Slide `incoming` in from a horizontal offset of `dx` while `outgoing` slides out the
    /// opposite way (a page turn), then run `completion` (the caller removes the outgoing).
    /// Transform-based, so neither terminal reflows. Honors Reduce Motion.
    static func slideSwap(
        incoming: NSView, outgoing: NSView?, dx: CGFloat,
        duration: CFTimeInterval = pageSlideDuration, completion: @escaping () -> Void
    ) {
        incoming.wantsLayer = true
        guard let inLayer = incoming.layer else {
            completion()
            return
        }
        if isReduceMotionEnabled() {
            inLayer.transform = CATransform3DIdentity
            completion()
            return
        }
        // A hard-decelerating ease-out so the page lands/locks in rather than drifting.
        let landing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        inLayer.transform = CATransform3DIdentity  // model rests on-screen
        let slideIn = CABasicAnimation(keyPath: "transform.translation.x")
        slideIn.fromValue = dx
        slideIn.toValue = 0
        slideIn.duration = duration
        slideIn.timingFunction = landing

        let outLayer = outgoing?.layer
        outLayer?.transform = CATransform3DMakeTranslation(-dx, 0, 0)  // model ends off-screen
        let slideOut = CABasicAnimation(keyPath: "transform.translation.x")
        slideOut.fromValue = 0
        slideOut.toValue = -dx
        slideOut.duration = duration
        slideOut.timingFunction = landing

        run(completion: completion) {
            inLayer.add(slideIn, forKey: "motion.slide")
            outLayer?.add(slideOut, forKey: "motion.slide")
        }
    }

    /// Opacity ramp — a new-tab canvas fading in. Honors Reduce Motion.
    static func fade(
        _ view: NSView, to opacity: Float,
        duration: CFTimeInterval = fadeDuration, completion: (() -> Void)? = nil
    ) {
        view.wantsLayer = true
        guard let layer = view.layer else {
            completion?()
            return
        }
        if isReduceMotionEnabled() {
            layer.opacity = opacity
            completion?()
            return
        }
        let from = layer.opacity  // model value — callers set it before fading
        layer.opacity = opacity
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = opacity
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        run(completion: completion) {
            layer.add(anim, forKey: "motion.opacity")
        }
    }

    /// Explicit ease of a single layer property old→new. Layer-backed `NSView`s disable
    /// implicit layer animations, so halo border/shadow and button/chip tints must be
    /// animated explicitly. Reads the current presentation value as the start so rapid
    /// interruptions stay smooth.
    static func ease(
        _ layer: CALayer,
        keyPath: String,
        to value: Any?,
        duration: CFTimeInterval = haloDuration,
        completion: (() -> Void)? = nil
    ) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        layer.setValue(value, forKeyPath: keyPath)

        if isReduceMotionEnabled() {
            completion?()
            return
        }

        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = value
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        run(completion: completion) {
            layer.add(anim, forKey: "motion.\(keyPath)")
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// A scale transform about the center of `bounds`, independent of the layer's
    /// `anchorPoint` — so a card scales from its middle whether AppKit anchored its
    /// backing layer at the center or a corner.
    static func centeredScale(_ scale: CGFloat, in bounds: CGRect) -> CATransform3D {
        let cx = bounds.midX
        let cy = bounds.midY
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }

    // MARK: - Internals

    private static func run(completion: (() -> Void)?, _ add: () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { completion?() }
        add()
        CATransaction.commit()
    }
}
