import AppKit

// The Connect screen's host emblem: the host's signature as a dot matrix on a rounded tile, raining while it connects.
final class HostEmblemView: NSView, ThemeReapplying {
    static let tileSide: CGFloat = 84
    private static let cellSide: CGFloat = 7
    private static let cellRadius = ChromeMetrics.Radius.icon(cellSide)
    private static let cellGap = ChromeMetrics.Spacing.s4
    private static let levelKey = "emblem.level"
    private static let colorKey = "emblem.color"

    private struct Palette {
        let ink: CGColor
        let accent: CGColor
        let glyph: CGColor?
    }

    private struct Run {
        let motion: HostEmblemMotion
        let startedAt: CFTimeInterval
        var glyph: HostEmblemGlyph?
    }

    private let lit: [Bool]
    private let cells: [CALayer]
    private let sheen = CAGradientLayer()
    private let lights: [CALayer]
    private var isDimmed = false
    private var glyph: HostEmblemGlyph?
    private var run: Run?
    private var runs = 0
    private var segmentsPlayed = 0

    init(host: SSHHostID) {
        lit = HostSignature.cells(of: host)
        cells = lit.map { _ in CALayer() }
        lights = lit.map { _ in CALayer() }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.tileSide, height: Self.tileSide))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.icon(Self.tileSide)
        layer?.cornerCurve = .continuous
        layer?.borderWidth = ChromeMetrics.Border.width
        layer?.masksToBounds = true
        sheen.frame = bounds
        ChipSheen.shape(sheen, .tile)
        layer?.addSublayer(sheen)
        let grid = CGFloat(HostSignature.side) * Self.cellSide + CGFloat(HostSignature.side - 1) * Self.cellGap
        let origin = (Self.tileSide - grid) / 2
        for (index, (cell, light)) in zip(cells, lights).enumerated() {
            let row = index / HostSignature.side
            let column = index % HostSignature.side
            cell.frame = NSRect(
                x: origin + CGFloat(column) * (Self.cellSide + Self.cellGap),
                y: origin + CGFloat(HostSignature.side - 1 - row) * (Self.cellSide + Self.cellGap),
                width: Self.cellSide, height: Self.cellSide)
            cell.cornerRadius = Self.cellRadius
            light.frame = cell.bounds
            light.cornerRadius = Self.cellRadius
            cell.addSublayer(light)
            layer?.addSublayer(cell)
        }
        setAccessibilityElement(false)
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.tileSide, height: Self.tileSide) }

    func setDimmed(_ dimmed: Bool) {
        guard dimmed != isDimmed else { return }
        isDimmed = dimmed
        reapplyTheme()
    }

    func show(_ glyph: HostEmblemGlyph?) {
        guard glyph != self.glyph || run != nil else { return }
        endRun()
        self.glyph = glyph
        reapplyTheme()
    }

    // Reduce Motion keeps the signature still; the answer then cross-fades in.
    func startRain(at now: CFTimeInterval) {
        guard run == nil else { return }
        glyph = nil
        reapplyTheme()
        guard !Motion.isReduceMotionEnabled() else { return }
        runs += 1
        run = Run(motion: HostEmblemMotion(signature: lit, seed: UInt64.random(in: .min ... .max)), startedAt: now)
        playRain(from: now, generation: runs)
    }

    @discardableResult
    func resolve(to glyph: HostEmblemGlyph, at now: CFTimeInterval) -> CFTimeInterval {
        guard var run, run.glyph == nil else {
            endRun()
            self.glyph = glyph
            if let layer { Motion.crossfade(layer, duration: Motion.HostConnect.reducedCrossfade, whenReduced: true) }
            reapplyTheme()
            return now + Motion.HostConnect.reducedCrossfade
        }
        run.motion.resolve(to: glyph, at: now - run.startedAt)
        run.glyph = glyph
        self.run = run
        self.glyph = glyph
        let settles = run.startedAt + (run.motion.settledAt ?? 0)
        let generation = runs
        play(run, from: now, to: settles) { [weak self] in self?.finishRun(generation) }
        return settles
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = chrome.background.nsColor.cgColor
        layer?.borderColor = chrome.fill(alpha: ChromeTheme.border).cgColor
        let off = chrome.fill(.active).cgColor
        cells.forEach { $0.backgroundColor = off }
        if let run {
            runs += 1
            let now = CACurrentMediaTime()
            guard run.glyph != nil else { return playRain(from: now, generation: runs) }
            let settles = run.startedAt + (run.motion.settledAt ?? 0)
            if now < settles {
                let generation = runs
                return play(run, from: now, to: settles) { [weak self] in self?.finishRun(generation) }
            }
            endRun()
        }
        let on = glyph.map { Self.color(of: $0, in: chrome) } ?? chrome.ink(isDimmed ? .muted : .normal).cgColor
        for (light, isLit) in zip(lights, glyph?.cells ?? lit) {
            light.removeAnimation(forKey: Self.levelKey)
            light.removeAnimation(forKey: Self.colorKey)
            light.backgroundColor = on
            light.opacity = isLit ? 1 : 0
        }
    }

    private func endRun() {
        run = nil
        runs += 1
    }

    private func finishRun(_ generation: Int) {
        guard generation == runs, run != nil else { return }
        endRun()
        reapplyTheme()
    }

    private func playRain(from start: CFTimeInterval, generation: Int) {
        guard let run, run.glyph == nil, generation == runs else { return }
        segmentsPlayed += 1
        let end = start + Motion.HostConnect.rainSegment
        play(run, from: start, to: end) { [weak self] in self?.playRain(from: end, generation: generation) }
    }

    private func play(_ run: Run, from start: CFTimeInterval, to end: CFTimeInterval, then next: (() -> Void)? = nil) {
        let palette = palette(for: run.glyph)
        let steps = max(1, Int(((end - start) * Motion.HostConnect.framesPerSecond).rounded(.up)))
        let times = (0...steps).map { start + (end - start) * Double($0) / Double(steps) }
        let keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        let begin = layer?.convertTime(start, from: nil) ?? start
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(next)
        for (index, light) in lights.enumerated() {
            let samples = times.map { run.motion.cell(index, at: $0 - run.startedAt) }
            let colors = samples.map { Self.color(of: $0, in: palette) }
            light.opacity = Float(samples.last?.level ?? 0)
            light.backgroundColor = colors.last
            light.add(
                Self.track("opacity", samples.map { Float($0.level) }, keyTimes, begin, end - start),
                forKey: Self.levelKey)
            light.add(Self.track("backgroundColor", colors, keyTimes, begin, end - start), forKey: Self.colorKey)
        }
        CATransaction.commit()
    }

    private static func track(
        _ keyPath: String, _ values: [Any], _ keyTimes: [NSNumber], _ begin: CFTimeInterval,
        _ duration: CFTimeInterval
    ) -> CAKeyframeAnimation {
        let track = CAKeyframeAnimation(keyPath: keyPath)
        track.values = values
        track.keyTimes = keyTimes
        track.beginTime = begin
        track.duration = duration
        track.fillMode = .backwards
        return track
    }

    private func palette(for glyph: HostEmblemGlyph?) -> Palette {
        let chrome = Theme.current.chrome
        return Palette(
            ink: chrome.ink(.normal).cgColor, accent: chrome.accent.nsColor.cgColor,
            glyph: glyph.map { Self.color(of: $0, in: chrome) })
    }

    private static func color(of cell: HostEmblemMotion.Cell, in palette: Palette) -> CGColor {
        let rain = mix(palette.ink, palette.accent, cell.accentMix)
        guard let glyph = palette.glyph else { return rain }
        return mix(rain, glyph, cell.glyphMix)
    }

    private static func mix(_ a: CGColor, _ b: CGColor, _ t: Double) -> CGColor {
        guard let a = a.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
            let b = b.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
            a.count == 4, b.count == 4
        else { return t < 0.5 ? a : b }
        let t = CGFloat(t)
        return CGColor(
            srgbRed: a[0] + (b[0] - a[0]) * t, green: a[1] + (b[1] - a[1]) * t, blue: a[2] + (b[2] - a[2]) * t,
            alpha: a[3] + (b[3] - a[3]) * t)
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func color(of glyph: HostEmblemGlyph, in chrome: ChromeTheme) -> CGColor {
        switch glyph {
        case .check: return chrome.positive.nsColor.cgColor
        case .cross: return chrome.destructive.nsColor.cgColor
        }
    }

    var litForTesting: [Bool] { lit }
    var glyphForTesting: HostEmblemGlyph? { glyph }
    var isRainingForTesting: Bool { run != nil && run?.glyph == nil }
    var segmentsPlayedForTesting: Int { segmentsPlayed }
    var cellColorsForTesting: [CGColor?] {
        lights.map { $0.opacity > 0 ? $0.backgroundColor : cells.first?.backgroundColor }
    }
    var tileFillForTesting: CGColor? { layer?.backgroundColor }
    var hasSheenUnderCellsForTesting: Bool {
        layer?.sublayers?.first === sheen && sheen.colors?.count == ChipSheen.colors(.tile).count
    }
}
