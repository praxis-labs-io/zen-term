import AppKit

/// One motion system for the whole chrome. All timing lives here so every window/pane
/// movement feels like the same spring. Structural motion is a snappy spring with a
/// slight overshoot; halo/tint eases are deliberately faster so they never lag rapid
/// focus nav; region dissolves get a short crossfade.
///
/// Honors Reduce Motion globally — when on, every primitive applies its final state
/// instantly and runs the completion **synchronously**, so callers that sequence work
/// in the completion (mutate-then-rebuild, detach-after-close) behave identically.
///
/// Chrome-only (AppKit + Core Animation). Never touches a terminal backend.
enum Motion {
    /// Which docked edge a panel slides from.
    enum Edge {
        case top, bottom, leading, trailing
    }

    // MARK: - Timing

    /// Structural spring — panels/cards appearing, drawer slides, new pane/tab. ~0.7
    /// damping ratio (gentle overshoot), ~0.24s settle. Snappy over smooth.
    enum Spring {
        static let mass: CGFloat = 1
        static let stiffness: CGFloat = 1600
        static let damping: CGFloat = 44

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

    /// Halo / tint ease — faster than structural so it never trails ⌘hjkl focus nav.
    static let haloDuration: CFTimeInterval = 0.12
    /// Region crossfade — zoom / tab-switch dissolves.
    static let crossfadeDuration: CFTimeInterval = 0.16
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

    /// Spring-translate a full-size panel in/out from a docked edge. The panel keeps its
    /// full size the whole time (never a size animation) so an attached PTY never sees a
    /// degenerate frame. `appearing` false slides it back out (caller detaches in
    /// `completion`).
    static func slide(
        _ view: NSView,
        fromEdge edge: Edge,
        distance: CGFloat,
        appearing: Bool,
        completion: (() -> Void)? = nil
    ) {
        view.wantsLayer = true
        guard let layer = view.layer else { completion?(); return }

        let offset = slideOffset(edge: edge, distance: distance)
        let offscreen = CATransform3DMakeTranslation(offset.width, offset.height, 0)
        let targetTransform = appearing ? CATransform3DIdentity : offscreen

        if isReduceMotionEnabled() {
            layer.transform = CATransform3DIdentity
            completion?()
            return
        }

        let fromTransform = appearing ? offscreen : currentTransform(of: layer)
        layer.transform = targetTransform

        let spring = Spring.make(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: fromTransform)
        spring.toValue = NSValue(caTransform3D: targetTransform)

        run(completion: completion) {
            layer.add(spring, forKey: "motion.transform")
        }
    }

    /// Opacity ramp. Zoom sibling fades, tab-switch crossfade.
    static func fade(
        _ view: NSView,
        to opacity: Float,
        duration: CFTimeInterval = crossfadeDuration,
        completion: (() -> Void)? = nil
    ) {
        view.wantsLayer = true
        guard let layer = view.layer else { completion?(); return }

        if isReduceMotionEnabled() {
            layer.opacity = opacity
            completion?()
            return
        }

        let from = layer.opacity  // model value — callers set it before crossfading
        layer.opacity = opacity

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = opacity
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        run(completion: completion) {
            layer.add(fade, forKey: "motion.opacity")
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

    /// The fully-offscreen translation for a panel docked at `edge`, in the layer's
    /// (unflipped, +y up) coordinate space: bottom pushes down, trailing pushes right.
    static func slideOffset(edge: Edge, distance: CGFloat) -> CGSize {
        switch edge {
        case .top: return CGSize(width: 0, height: distance)
        case .bottom: return CGSize(width: 0, height: -distance)
        case .leading: return CGSize(width: -distance, height: 0)
        case .trailing: return CGSize(width: distance, height: 0)
        }
    }

    // MARK: - Internals

    private static func run(completion: (() -> Void)?, _ add: () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { completion?() }
        add()
        CATransaction.commit()
    }

    private static func currentTransform(of layer: CALayer) -> CATransform3D {
        layer.presentation()?.transform ?? layer.transform
    }
}
