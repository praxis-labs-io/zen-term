import AppKit

enum BrandMark {
    private static var loaded: [String: NSImage?] = [:]

    /// Returns a copy: callers set `size`, which on a shared instance would resize every other caller's mark.
    static func image(_ name: String) -> NSImage? {
        if let cached = loaded[name] { return cached?.copy() as? NSImage }
        let image = load(name)
        loaded[name] = image
        return image?.copy() as? NSImage
    }

    private static func load(_ name: String) -> NSImage? {
        guard
            let url = ZenTermResources.bundle.url(
                forResource: name, withExtension: "svg", subdirectory: "Resources"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        return image
    }
}
