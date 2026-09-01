import AppKit

/// Tool-float icons in two sections: outline symbols, then brand marks. Both are line art, and
/// they share picker cells, so a filled symbol would outweigh the marks it sits beside.
/// A brand earns a cell only with a terminal UI behind it (`docker` for lazydocker, `postgres`
/// for pgcli); one that only opens a window or a plain CLI can't be floated.
enum IconCatalog {
    static let defaultSymbol = "square.on.square"

    /// A titled run of cells, laid out 8-wide under its own heading by `IconPickerField`.
    struct Section {
        let title: String
        let symbols: [String]
    }

    /// 48 symbols → six full rows of the 8-wide grid (`IconCatalogTests` pins the multiple).
    /// Grouped by metaphor, a row at a time: shell/code/build/test, pipeline/config/perf,
    /// monitoring/infra/storage, data/docs/logs, find/files/comms, security/AI/media/panes.
    static let symbols: [String] = [
        "square.on.square", "terminal", "curlybraces.square", "applescript",
        "play.rectangle", "ladybug", "hammer", "flask",
        "flowchart", "bolt", "flame", "gearshape",
        "switch.2", "gauge.with.needle", "stopwatch", "chart.bar",
        "waveform.path.ecg.rectangle", "cpu", "memorychip", "cube",
        "shippingbox", "antenna.radiowaves.left.and.right", "cloud", "externaldrive",
        "cylinder.split.1x2", "tablecells", "archivebox", "doc.text",
        "square.text.square", "list.bullet.rectangle", "list.bullet.clipboard", "flag",
        "magnifyingglass", "folder", "folder.badge.gearshape", "envelope",
        "bubble.left.and.bubble.right", "paperplane", "lock", "key",
        "shield", "brain", "sparkles", "atom",
        "puzzlepiece", "waveform", "rectangle.3.group", "square.grid.2x2",
    ]

    /// 19 marks: VCS, editors, agents, then services. Short by five of a full row, which is why
    /// they're last — a ragged row reads as the end of the grid, not a hole in it.
    static let brands: [String] = [
        "git", "github", "linear", "neovim",
        "vim", "emacs", "helix", "claude",
        "openai", "gemini", "copilot", "opencode",
        "ollama", "docker", "kubernetes", "postgres",
        "sqlite", "slack", "spotify",
    ]

    static let all: [String] = symbols + brands

    /// The picker's sections. A float pinned to a symbol off the roster keeps its own leading
    /// section, so editing that float never silently drops its glyph.
    static func sections(including selected: String) -> [Section] {
        var sections: [Section] = []
        if !all.contains(selected) {
            sections.append(Section(title: "Current", symbols: [selected]))
        }
        sections.append(Section(title: "Symbols", symbols: symbols))
        sections.append(Section(title: "Brand marks", symbols: brands))
        return sections
    }

    /// The picker's label for a symbol. Roster cells are named for the job ("Run", not "Play
    /// rectangle"), so most are overridden below; the fallback is for a user's own symbol.
    static func displayName(_ symbol: String) -> String {
        if let name = displayOverrides[symbol] { return name }
        let stem = trimmingFillSuffix(symbol)
        let spaced = stem.replacingOccurrences(of: ".", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// A trailing fill marker is a rendering variant, not part of the name: "heart.fill" is a heart.
    /// Only the suffix goes — "folder.fill.badge.gearshape" keeps its middle.
    private static func trimmingFillSuffix(_ symbol: String) -> String {
        for suffix in [".fill", ".filled"] where symbol.hasSuffix(suffix) {
            return String(symbol.dropLast(suffix.count))
        }
        return symbol
    }

    /// Entries for symbols off the roster are load-bearing: a float pinned to a dropped icon keeps
    /// its label instead of falling back to the raw symbol name.
    private static let displayOverrides: [String: String] = [
        // Roster: named for the job, not the glyph.
        "square.on.square": "Float",
        "curlybraces.square": "Code",
        "applescript": "Script",
        "play.rectangle": "Run",
        "ladybug": "Debug",
        "hammer": "Build",
        "flask": "Tests",
        "flowchart": "Pipeline",
        "bolt": "Fast",
        "flame": "Hot",
        "gearshape": "Settings",
        "switch.2": "Toggles",
        "gauge.with.needle": "Gauge",
        "stopwatch": "Benchmark",
        "chart.bar": "Chart",
        "waveform.path.ecg.rectangle": "Monitor",
        "cpu": "CPU",
        "memorychip": "Memory",
        "cube": "Container",
        "shippingbox": "Package",
        "antenna.radiowaves.left.and.right": "Signal",
        "externaldrive": "Storage",
        "cylinder.split.1x2": "Database",
        "tablecells": "Table",
        "archivebox": "Archive",
        "doc.text": "Document",
        "square.text.square": "Notes",
        "list.bullet.rectangle": "Logs",
        "list.bullet.clipboard": "Checklist",
        "magnifyingglass": "Search",
        "folder": "Files",
        "folder.badge.gearshape": "Config dir",
        "envelope": "Email",  // humanizes to "Envelope" on its own; the metaphor is mail
        "bubble.left.and.bubble.right": "Chat",
        "paperplane": "HTTP client",
        "lock": "Secrets",
        "key": "Keys",
        "shield": "Security",
        "brain": "Model",
        "sparkles": "AI",
        "puzzlepiece": "Plugins",
        "waveform": "Music",
        "rectangle.3.group": "Panes",
        "square.grid.2x2": "Dashboard",
        "github": "GitHub",
        "neovim": "Neovim",
        "openai": "OpenAI",
        "opencode": "OpenCode",
        "sqlite": "SQLite",
        "square.fill.on.square": "Float",  // ToolFloat.scratch
        // Dropped: kept so a float still configured with one keeps its label.
        "apple.terminal.on.rectangle": "Terminal window",
        "chevron.left.forwardslash.chevron.right": "Code",
        "wrench.and.screwdriver": "Tools",
        "slider.horizontal.3": "Controls",
        "chart.line.uptrend.xyaxis": "Line chart",
        "filemenu.and.selection": "Outline",
        "arrow.triangle.branch": "Git branch",
        "arrow.triangle.pull": "Pull request",
        "plus.forwardslash.minus": "Diff",
        "note.text": "Notes",
        "htop": "htop",  // lowercase is the tool's own name
        "slack": "Slack",
        "spotify": "Spotify",
    ]

    /// An SF Symbol, else a bundled brand mark. SF Symbol first, so a mark name must never
    /// collide with a real symbol (`IconCatalogTests` holds the line). A mark carries no symbol
    /// metadata and would draw at its authored 24pt, so it is sized off `pointSize` here rather
    /// than left to the caller to remember.
    static func image(
        _ symbol: String, pointSize: CGFloat = 14, weight: NSFont.Weight = .medium
    ) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            return image.withSymbolConfiguration(config)
        }
        guard let brand = BrandMark.image(symbol) else { return nil }
        let box = pointSize + brandNudge
        brand.size = NSSize(width: box, height: box)
        return brand
    }

    /// A mark carries no internal padding where a symbol does, so it needs a slightly larger box to
    /// read at the same size as the glyphs around it.
    static let brandNudge: CGFloat = 1.5

    /// The proper Git logo (the bundled `git` brand mark), sized as a small inline badge. Shared by
    /// the ⌘P picker and the Settings → Workspaces list to mark a workspace whose folder is a repo,
    /// so the two never drift. A template image, so the caller tints it like any SF Symbol.
    static func gitBadge(pointSize: CGFloat = 12) -> NSImage? {
        guard let image = BrandMark.image("git") else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }
}
