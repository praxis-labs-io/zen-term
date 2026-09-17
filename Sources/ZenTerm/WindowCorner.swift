import AppKit

enum WindowCorner {
    /// The system window corner radius. AppKit exposes none, and macOS 26 raised it from 11 to 16,
    /// so a pane flush to the window edge reads ragged against a constant.
    @MainActor static let radius: CGFloat = resolve() ?? fallback

    /// The macOS 14 and 15 value, used when the private read stops working.
    private static let fallback: CGFloat = 11

    @MainActor
    private static func resolve() -> CGFloat? {
        let probe = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.titled], backing: .buffered, defer: true)
        let key = "_cornerRadius"
        guard probe.responds(to: NSSelectorFromString(key)) else { return nil }
        guard let value = probe.value(forKey: key) as? NSNumber else { return nil }
        let radius = CGFloat(value.doubleValue)
        return radius > 0 ? radius : nil
    }
}
