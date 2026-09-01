import AppKit

/// The curated set of tool-float icons, in two sections: filled dev-tooling symbols, then brand
/// marks. `image` resolves either the same way the dock does — an SF Symbol, else a bundled brand
/// mark ("git", "docker", "claude", …).
///
/// The symbols are filled because every brand mark is a single solid path, and a hairline outline
/// beside one reads as a different weight of thing. Where SF Symbols has no fill for a metaphor,
/// the metaphor changed rather than the glyph gaining a `.circle.fill` enclosure, which reads as a
/// badge and clashes harder than the outline did.
///
/// This roster is what a *user* pins to their own floats. The app's own behaviors stay on outline
/// variants — the dock's split buttons, the scratch float — so a built-in reads as chrome rather
/// than as another tool the user added.
///
/// A brand earns a cell by having a terminal UI behind it, first- or third-party: `docker` stands
/// for lazydocker, `kubernetes` for k9s, `postgres` for pgcli, `slack` for wee-slack. A brand whose
/// only interface is a window (Zed, Obsidian) or a plain CLI (Homebrew, Tailscale) doesn't, because
/// you can't float it.
enum IconCatalog {
    static let defaultSymbol = "square.stack.fill"

    /// A titled run of cells, laid out 8-wide under its own heading by `IconPickerField`.
    struct Section {
        let title: String
        let symbols: [String]
    }

    /// 48 symbols → six full rows of the 8-wide grid (`IconCatalogTests` pins the multiple).
    /// Grouped by metaphor, a row at a time: shell/code/build/test, pipeline/config/perf,
    /// monitoring/infra/storage, data/docs/logs, find/files/comms, security/AI/media/panes.
    static let symbols: [String] = [
        "square.stack.fill", "terminal.fill", "curlybraces.square.fill", "applescript.fill",
        "play.rectangle.fill", "ladybug.fill", "hammer.fill", "flask.fill",
        "flowchart.fill", "bolt.fill", "flame.fill", "gearshape.fill",
        "switch.2", "gauge.with.needle.fill", "stopwatch.fill", "chart.bar.fill",
        "waveform.path.ecg.rectangle.fill", "cpu.fill", "memorychip.fill", "cube.fill",
        "shippingbox.fill", "antenna.radiowaves.left.and.right", "cloud.fill", "externaldrive.fill",
        "cylinder.split.1x2.fill", "tablecells.fill", "archivebox.fill", "doc.text.fill",
        "square.text.square.fill", "list.bullet.rectangle.fill", "list.bullet.clipboard.fill",
        "flag.fill",
        "magnifyingglass.circle.fill", "folder.fill", "folder.fill.badge.gearshape", "envelope.fill",
        "bubble.left.and.bubble.right.fill", "paperplane.fill", "lock.fill", "key.fill",
        "shield.fill", "brain.fill", "sparkles", "atom",
        "puzzlepiece.fill", "waveform", "rectangle.3.group.fill", "square.grid.2x2.fill",
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

    /// A humanized, sentence-case label for a symbol — the picker shows this instead of the raw
    /// `dotted.symbol.name`. Roster cells are named for what they're *for* ("Run", not "Play
    /// rectangle"), so they all sit in the override table; the fallback below is what a user's own
    /// custom symbol gets.
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
        "square.stack.fill": "Float",
        "curlybraces.square.fill": "Code",
        "applescript.fill": "Script",
        "play.rectangle.fill": "Run",
        "ladybug.fill": "Debug",
        "hammer.fill": "Build",
        "flask.fill": "Tests",
        "flowchart.fill": "Pipeline",
        "bolt.fill": "Fast",
        "flame.fill": "Hot",
        "gearshape.fill": "Settings",
        "switch.2": "Toggles",
        "gauge.with.needle.fill": "Gauge",
        "stopwatch.fill": "Benchmark",
        "chart.bar.fill": "Chart",
        "waveform.path.ecg.rectangle.fill": "Monitor",
        "cpu.fill": "CPU",
        "memorychip.fill": "Memory",
        "cube.fill": "Container",
        "shippingbox.fill": "Package",
        "antenna.radiowaves.left.and.right": "Signal",
        "externaldrive.fill": "Storage",
        "cylinder.split.1x2.fill": "Database",
        "tablecells.fill": "Table",
        "archivebox.fill": "Archive",
        "doc.text.fill": "Document",
        "square.text.square.fill": "Notes",
        "list.bullet.rectangle.fill": "Logs",
        "list.bullet.clipboard.fill": "Checklist",
        "magnifyingglass.circle.fill": "Search",
        "folder.fill": "Files",
        "folder.fill.badge.gearshape": "Config dir",
        "envelope.fill": "Email",  // humanizes to "Envelope" on its own; the metaphor is mail
        "bubble.left.and.bubble.right.fill": "Chat",
        "paperplane.fill": "HTTP client",
        "lock.fill": "Secrets",
        "key.fill": "Keys",
        "shield.fill": "Security",
        "brain.fill": "Model",
        "sparkles": "AI",
        "puzzlepiece.fill": "Plugins",
        "rectangle.3.group.fill": "Panes",
        "square.grid.2x2.fill": "Dashboard",
        "github": "GitHub",
        "neovim": "Neovim",
        "openai": "OpenAI",
        "opencode": "OpenCode",
        "sqlite": "SQLite",
        // Dropped: kept so a float still configured with one keeps its label.
        "square.on.square": "Float",
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
        "plus.forwardslash.minus": "Diff",
        "note.text": "Notes",
        "bubble.left.and.bubble.right": "Chat",
        "envelope": "Email",
        "htop": "htop",  // lowercase is the tool's own name
        "slack": "Slack",
        "spotify": "Spotify",
    ]

    /// Resolve a symbol to an image: an SF Symbol, else a brand mark bundled in `Resources/`. The
    /// one place this fallback lives. `IconButton` renders the same catalog and used to carry its
    /// own copy. SF Symbol first, so a brand-mark name must never collide with a real symbol
    /// (`IconCatalogTests` holds the line).
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

    /// The box a brand mark needs to draw the same ink height as an SF Symbol at `pointSize`.
    ///
    /// An SF Symbol's ink runs a little taller than its point size (≈1.03×) while a mark's runs a
    /// little shorter than its box (≈0.96×), so a logo handed the same number draws bigger. The
    /// ratio is measured, and `IconButtonTests` re-measures it rather than trusting this comment.
    static func brandBoxMatching(pointSize: CGFloat) -> CGFloat { pointSize * brandBoxRatio }

    /// Measured across the roster's marks and symbols: 1.03 / 0.96.
    static let brandBoxRatio: CGFloat = 1.07

    /// The proper Git logo (the bundled `git` brand mark), sized as a small inline badge. Shared by
    /// the ⌘P picker and the Settings → Workspaces list to mark a workspace whose folder is a repo,
    /// so the two never drift. A template image, so the caller tints it like any SF Symbol.
    static func gitBadge(pointSize: CGFloat = 12) -> NSImage? {
        guard let image = BrandMark.image("git") else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }
}
