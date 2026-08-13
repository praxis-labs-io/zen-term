import AppKit

/// The curated set of tool-float icons — dev-tooling metaphors (shells, builds, VCS, metrics, infra,
/// files), laid out as an 8-wide grid by `IconPickerField`. `image` resolves a symbol the same way
/// the dock does: an SF Symbol, else a bundled brand mark ("git" / "github" / "linear" / "neovim").
enum IconCatalog {
    static let defaultSymbol = "square.on.square"

    /// 40 symbols → a tidy 8×5 grid, so the last row is never ragged (`columns = 8` in
    /// `IconPickerField`, and `IconCatalogTests` pins the multiple). A float's custom (non-catalog)
    /// symbol is shown alongside these by the picker so editing never loses it.
    ///
    /// Grouped by metaphor, roughly a row at a time: shell/code/build/debug, config/metrics,
    /// infra/data/docs, files/comms, run/VCS/auth — brand marks last.
    static let all: [String] = [
        "square.on.square", "terminal", "apple.terminal.on.rectangle",
        "chevron.left.forwardslash.chevron.right",
        "curlybraces", "hammer", "wrench.and.screwdriver", "ladybug",
        "gearshape", "slider.horizontal.3", "chart.bar", "chart.line.uptrend.xyaxis",
        "gauge", "cpu", "linear", "server.rack",
        "externaldrive", "cylinder.split.1x2", "tablecells", "network",
        "globe", "shippingbox", "filemenu.and.selection", "doc.text",
        "list.bullet.rectangle", "magnifyingglass", "folder", "tray.full",
        "checklist", "envelope", "bubble.left.and.bubble.right", "bolt",
        "play.rectangle", "arrow.triangle.branch", "arrow.triangle.pull", "key",
        "lock", "git", "github", "neovim",
    ]

    /// A humanized, sentence-case label for a symbol — the picker shows this instead of the raw
    /// `dotted.symbol.name`. A handful read better as an override; the rest just swap dots for spaces
    /// and capitalize the first word.
    static func displayName(_ symbol: String) -> String {
        if let name = displayOverrides[symbol] { return name }
        let spaced = symbol.replacingOccurrences(of: ".", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private static let displayOverrides: [String: String] = [
        "square.on.square": "Windows",
        "apple.terminal.on.rectangle": "Terminal window",
        "chevron.left.forwardslash.chevron.right": "Code",
        "wrench.and.screwdriver": "Tools",
        "slider.horizontal.3": "Controls",
        "chart.line.uptrend.xyaxis": "Line chart",
        "cylinder.split.1x2": "Database",
        "list.bullet.rectangle": "Logs",
        "filemenu.and.selection": "Outline",
        "doc.text": "Document",
        "play.rectangle": "Run",
        "arrow.triangle.branch": "Git branch",
        "arrow.triangle.pull": "Pull request",
        "note.text": "Notes",  // off the roster, but a float pinned to it keeps this label
        "bubble.left.and.bubble.right": "Chat",
        "envelope": "Email",  // humanizes to "Envelope" on its own; the metaphor is mail
        "git": "Git",
        "github": "GitHub",
        "linear": "Linear",
        "neovim": "Neovim",
        "spotify": "Spotify",  // off the roster, but a float pinned to it keeps this label
    ]

    /// Resolve a symbol to an image: an SF Symbol, else a bundled brand mark ("git", "github",
    /// "linear", "neovim", "spotify"). The one place this fallback lives — `IconButton` renders the same catalog and
    /// used to carry its own copy. SF Symbol first, so a brand-mark name must never collide with a
    /// real symbol (none do).
    ///
    /// A brand mark is a plain SVG with no symbol metadata, so a `SymbolConfiguration` does nothing
    /// to it: `brandSize` sizes it explicitly, and leaving it nil keeps the SVG's natural size.
    static func image(
        _ symbol: String, pointSize: CGFloat = 14, weight: NSFont.Weight = .medium,
        brandSize: CGFloat? = nil
    ) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            return image.withSymbolConfiguration(config)
        }
        guard let brand = BrandMark.image(symbol) else { return nil }
        if let brandSize { brand.size = NSSize(width: brandSize, height: brandSize) }
        return brand
    }

    /// The proper Git logo (the bundled `git` brand mark), sized as a small inline badge. Shared by
    /// the ⌘P picker and the Settings → Workspaces list to mark a workspace whose folder is a repo,
    /// so the two never drift. A template image, so the caller tints it like any SF Symbol.
    static func gitBadge(pointSize: CGFloat = 12) -> NSImage? {
        guard let image = BrandMark.image("git") else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }
}
