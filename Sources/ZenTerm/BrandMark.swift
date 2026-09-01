import AppKit

/// Loads a bundled brand mark (e.g. "github", "git", "docker", "claude"), a monochrome SVG in
/// `Resources/`, as a template image, so `IconButton` can show real logos SF Symbols don't ship. The SVG
/// is a solid path on transparent, so `isTemplate` makes it tint like any SF Symbol. Returns
/// nil for an unknown name (the caller falls back to leaving the button glyphless).
enum BrandMark {
    /// Marks already read off disk, keyed by name. A `nil` value is a name with no bundled SVG,
    /// memoized too so a miss costs one bundle lookup rather than one per call. Main-thread only —
    /// every caller is a view builder.
    private static var loaded: [String: NSImage?] = [:]

    /// The mark named `name`, or nil when nothing is bundled. Each caller gets its own copy:
    /// `gitBadge` and `IconCatalog.image` both set `size`, which on a shared instance would resize
    /// every other caller's. A copy shares representations, so it stays cheaper than re-reading —
    /// the palette rebuilds its rows per keystroke, which made this main-thread I/O once per row.
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
