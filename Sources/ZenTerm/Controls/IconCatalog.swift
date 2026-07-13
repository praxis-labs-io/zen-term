import AppKit

/// The curated set of tool-float icons — dev-tooling metaphors (shells, builds, VCS, metrics, infra,
/// files), laid out as an 8-wide grid by `IconPickerField`. `image` resolves a symbol the same way
/// the dock does: an SF Symbol, else a bundled brand mark ("git" / "github").
enum IconCatalog {
    static let defaultSymbol = "square.on.square"

    /// 40 symbols → a tidy 8×5 grid. A float's custom (non-catalog) symbol is shown alongside these
    /// by the picker so editing never loses it.
    static let all: [String] = [
        "square.on.square", "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces",
        "hammer", "wrench.and.screwdriver", "ladybug", "ant",
        "gearshape", "slider.horizontal.3", "chart.bar", "chart.line.uptrend.xyaxis",
        "gauge", "speedometer", "cpu", "memorychip",
        "server.rack", "externaldrive", "cylinder.split.1x2", "tablecells",
        "network", "globe", "cloud", "shippingbox",
        "cube", "puzzlepiece", "doc.text", "list.bullet.rectangle",
        "magnifyingglass", "folder", "tray.full", "checklist",
        "bolt", "play.rectangle", "arrow.triangle.branch", "arrow.triangle.pull",
        "key", "lock", "git", "github",
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
        "chevron.left.forwardslash.chevron.right": "Code",
        "wrench.and.screwdriver": "Tools",
        "slider.horizontal.3": "Controls",
        "chart.line.uptrend.xyaxis": "Line chart",
        "cylinder.split.1x2": "Database",
        "list.bullet.rectangle": "Logs",
        "doc.text": "Document",
        "play.rectangle": "Run",
        "arrow.triangle.branch": "Git branch",
        "arrow.triangle.pull": "Pull request",
        "git": "Git",
        "github": "GitHub",
    ]

    /// Resolve a symbol to an image: an SF Symbol, else a bundled brand mark ("git", "github").
    static func image(_ symbol: String, pointSize: CGFloat = 14) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            return image.withSymbolConfiguration(config)
        }
        return BrandMark.image(symbol)
    }

    /// The proper Git logo (the bundled `git` brand mark), sized as a small inline badge. Shared by
    /// the ⌘⇧P picker and the Settings → Workspaces list to mark a workspace whose folder is a repo,
    /// so the two never drift. A template image, so the caller tints it like any SF Symbol.
    static func gitBadge(pointSize: CGFloat = 12) -> NSImage? {
        guard let image = BrandMark.image("git") else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }
}
