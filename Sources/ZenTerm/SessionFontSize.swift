import CoreGraphics

/// Re-pushed after every reload: libghostty drops config font size for a surface once it was given an explicit size.
enum SessionFontSize {
    static let range: ClosedRange<CGFloat> = 6...32

    private(set) static var points: CGFloat = GeneralConfig.builtIn.fontSize

    /// `ConfigChange.theme` also covers colors, so this is what tells a changed size from a recolor.
    private static var base: CGFloat = GeneralConfig.builtIn.fontSize

    static func seed(from config: GeneralConfig) {
        base = config.fontSize
        points = config.fontSize
    }

    @discardableResult
    static func reseedIfBaseChanged(from config: GeneralConfig) -> Bool {
        guard config.fontSize != base else { return false }
        seed(from: config)
        return true
    }

    static func step(by delta: CGFloat) {
        points = min(max(points + delta, range.lowerBound), range.upperBound)
    }

    static func reset() { points = base }

    static var display: String {
        points == points.rounded()
            ? "\(Int(points))pt"
            : "\(points)pt"
    }
}
