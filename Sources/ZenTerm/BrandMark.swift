import AppKit

/// Loads a bundled brand mark (e.g. "github", "git") — a monochrome SVG in `Resources/` —
/// as a template image, so `IconButton` can show real logos SF Symbols don't ship. The SVG
/// is a solid path on transparent, so `isTemplate` makes it tint like any SF Symbol. Returns
/// nil for an unknown name (the caller falls back to leaving the button glyphless).
enum BrandMark {
    static func image(_ name: String) -> NSImage? {
        guard
            let url = ZenTermResources.bundle.url(
                forResource: name, withExtension: "svg", subdirectory: "Resources"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        return image
    }
}
