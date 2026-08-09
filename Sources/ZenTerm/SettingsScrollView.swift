import AppKit
import QuartzCore

/// The Settings detail scroll view: it eases toward a keyboard-driven position instead of snapping
/// to it. Arrow-nav lands one stop per keystroke, and the pitch between stops isn't uniform (rows sit
/// 35pt apart, a group boundary is 66 with the caption and its gap in between), so a snap per step at
/// key-repeat speed reads as a stutter that keeps changing size. Easing toward the *pending* position
/// turns a held arrow into one continuous scroll that settles where the last keystroke asked for.
///
/// Honors Reduce Motion by landing on the position immediately.
final class SettingsScrollView: NSScrollView {
    /// The glide closes `1 - 1/e` of the remaining distance per time constant. 75ms settles a single
    /// step in about a tenth of a second: still a glide, never a wait.
    private static let timeConstant: CFTimeInterval = 0.075
    /// Sub-pixel remainder. Land it and stop rather than tick forever on a distance nobody can see.
    private static let settled: CGFloat = 0.5

    private var pendingTarget: CGFloat?
    private var link: CADisplayLink?

    /// Where the content lands once the glide in flight settles — the baseline the next keystroke
    /// measures from. Measuring from the live position instead has every repeat of a held arrow
    /// compute its step from an offset that is still catching up, so the destination creeps.
    var pendingTop: CGFloat { pendingTarget ?? contentView.bounds.minY }

    /// Ease the content so document coordinate `top` sits at the top of the clip view, never leaving
    /// `focused` (document coords) outside it on the way.
    func glide(top: CGFloat, keeping focused: NSRect) {
        catchUp(to: focused)
        guard abs(top - contentView.bounds.minY) > Self.settled else {
            stop()
            return
        }
        pendingTarget = top
        guard !Motion.isReduceMotionEnabled() else {
            apply(top)
            stop()
            return
        }
        guard link == nil else { return }  // already ticking: the new target retargets it in flight
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Close whatever part of the glide's lag would leave `focused` outside the clip, before aiming at
    /// a new position. A held arrow repeats faster than the glide settles, so the content is genuinely
    /// behind — and a keystroke that moves focus somewhere the reader can't see is worse than a jump.
    /// From here the glide only travels toward a position that seats the row inside the clip, so it
    /// stays visible for the rest of the flight.
    private func catchUp(to focused: NSRect) {
        let current = contentView.bounds.minY
        let viewport = contentView.bounds.height
        let lowest = focused.maxY - viewport  // any less and the row's bottom is below the clip
        let highest = focused.minY  // any more and its top is above the clip
        if current > highest {
            apply(highest)
        } else if current < lowest, lowest <= highest {
            apply(lowest)  // the guard skips a row taller than the clip: showing its top wins
        }
    }

    /// A wheel or trackpad scroll outranks the glide: the reader is aiming by hand now, and a glide
    /// still closing on a keystroke's target would drag the content back out from under them.
    override func scrollWheel(with event: NSEvent) {
        stop()
        super.scrollWheel(with: event)
    }

    /// A section swap tears the scroll view out of the card while a glide may still be ticking, and a
    /// live display link retains its target.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    deinit { link?.invalidate() }

    @objc private func tick(_ link: CADisplayLink) {
        guard let target = pendingTarget else {
            stop()
            return
        }
        let current = contentView.bounds.minY
        let remaining = target - current
        guard abs(remaining) > Self.settled else {
            apply(target)
            stop()
            return
        }
        // Clamped both ways: a dropped frame must not teleport the content, and a display link that
        // reports no duration yet must not stall the glide at zero.
        let frame = min(max(link.duration, 1.0 / 120), 1.0 / 30)
        apply(current + remaining * CGFloat(min(1, frame / Self.timeConstant)))
    }

    private func apply(_ top: CGFloat) {
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: top))
        reflectScrolledClipView(contentView)
    }

    private func stop() {
        link?.invalidate()
        link = nil
        pendingTarget = nil
    }
}
