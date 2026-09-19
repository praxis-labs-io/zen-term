import AppKit

enum Motion {
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

    static let haloDuration: CFTimeInterval = 0.18
    static let pageSlideDuration: CFTimeInterval = 0.28
    static let landingTiming = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let fadeDuration: CFTimeInterval = 0.18
    static let entranceFadeDuration: CFTimeInterval = 0.11
    static let entranceScale: CGFloat = 0.97
    static let zoomScale: CGFloat = 0.9

    static var isReduceMotionEnabled: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func springScaleFade(_ view: NSView, appearing: Bool, completion: (() -> Void)? = nil) {
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        guard let layer = view.layer else { completion?(); return }

        let shownTransform = CATransform3DIdentity
        let hiddenTransform = centeredScale(entranceScale, in: layer.bounds)
        let targetTransform = appearing ? shownTransform : hiddenTransform
        let targetOpacity: Float = appearing ? 1 : 0

        if isReduceMotionEnabled() {
            layer.transform = targetTransform
            layer.opacity = targetOpacity
            completion?()
            return
        }

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

    static func zoomPop(_ view: NSView, growing: Bool) {
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        guard let layer = view.layer else { return }
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        if isReduceMotionEnabled() { return }

        let fromScale = growing ? zoomScale : 2 - zoomScale
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: centeredScale(fromScale, in: layer.bounds))
        scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        scale.duration = pageSlideDuration
        scale.timingFunction = landingTiming

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = entranceFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        run(completion: nil) {
            layer.add(scale, forKey: "zoom.transform")
            layer.add(fade, forKey: "zoom.opacity")
        }
    }

    static func slideSwap(
        incoming: NSView, outgoing: NSView?, offset: CGVector,
        duration: CFTimeInterval = pageSlideDuration, completion: @escaping () -> Void
    ) {
        incoming.wantsLayer = true
        outgoing?.wantsLayer = true
        guard let inLayer = incoming.layer else {
            completion()
            return
        }
        if isReduceMotionEnabled() {
            inLayer.transform = CATransform3DIdentity
            completion()
            return
        }
        inLayer.transform = CATransform3DIdentity
        let slideIn = CABasicAnimation(keyPath: "transform.translation")
        slideIn.fromValue = NSValue(size: NSSize(width: offset.dx, height: offset.dy))
        slideIn.toValue = NSValue(size: .zero)
        slideIn.duration = duration
        slideIn.timingFunction = landingTiming

        let outLayer = outgoing?.layer
        outLayer?.transform = CATransform3DMakeTranslation(-offset.dx, -offset.dy, 0)
        let slideOut = CABasicAnimation(keyPath: "transform.translation")
        slideOut.fromValue = NSValue(size: .zero)
        slideOut.toValue = NSValue(size: NSSize(width: -offset.dx, height: -offset.dy))
        slideOut.duration = duration
        slideOut.timingFunction = landingTiming

        run(completion: completion) {
            inLayer.add(slideIn, forKey: "motion.slide")
            outLayer?.add(slideOut, forKey: "motion.slide")
        }
    }

    static func drawerSlide(
        panel: NSView, opening: Bool, parkOffset: CGVector,
        animate: [(constraint: NSLayoutConstraint, to: CGFloat)], in root: NSView,
        beforeSlide: () -> Void, completion: @escaping () -> Void
    ) {
        let slideStarts = animate.map(\.constraint.constant)
        for (constraint, target) in animate { constraint.constant = target }
        root.layoutSubtreeIfNeeded()
        beforeSlide()
        for (pair, start) in zip(animate, slideStarts) { pair.constraint.constant = start }
        root.layoutSubtreeIfNeeded()

        let parked = CATransform3DMakeTranslation(parkOffset.dx, parkOffset.dy, 0)
        let restT = opening ? CATransform3DIdentity : parked
        panel.wantsLayer = true
        panel.layer?.transform = restT
        let slideAnim = CABasicAnimation(keyPath: "transform")
        slideAnim.fromValue = NSValue(caTransform3D: opening ? parked : CATransform3DIdentity)
        slideAnim.toValue = NSValue(caTransform3D: restT)
        slideAnim.duration = pageSlideDuration
        slideAnim.timingFunction = landingTiming

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = pageSlideDuration
            ctx.timingFunction = landingTiming
            for (constraint, target) in animate { constraint.animator().constant = target }
            panel.layer?.add(slideAnim, forKey: "drawer.slide")
        } completionHandler: {
            completion()
        }
    }

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
        let from = layer.opacity
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

    /// Layer-backed views disable implicit layer animations, so these properties are animated explicitly.
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

    /// Independent of `anchorPoint`, which AppKit may put at the center or a corner.
    static func centeredScale(_ scale: CGFloat, in bounds: CGRect) -> CATransform3D {
        let cx = bounds.midX
        let cy = bounds.midY
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }

    private static func run(completion: (() -> Void)?, _ add: () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { completion?() }
        add()
        CATransaction.commit()
    }
}
