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
        "square.on.square.softfill": "Float",
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
    /// one place this fallback lives. SF Symbol first, so a brand-mark name must never collide with
    /// a real symbol (`IconCatalogTests` holds the line).
    ///
    /// A mark is a plain SVG with no symbol metadata, so a `SymbolConfiguration` does nothing to it
    /// and it would otherwise draw at its authored 24pt — most of a Settings row. It is sized off
    /// `pointSize` here instead, so every caller gets a mark scaled to the symbols beside it
    /// whether or not it thought to ask.
    static func image(
        _ symbol: String, pointSize: CGFloat = 14, weight: NSFont.Weight = .medium
    ) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let pair = composedGlyphs[symbol] { return compose(pair, config: config) }
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
    static let brandNudge: CGFloat = 1

    /// Glyphs SF Symbols has no variant for. `square.on.square` fills its front face solid or not
    /// at all, and hierarchical rendering dims the *back* face rather than lightening the front, so
    /// a lightly-filled front has to be composed: the outline over its filled twin, washed back.
    private static let composedGlyphs: [String: (outline: String, filled: String)] = [
        "square.on.square.softfill": ("square.on.square", "square.fill.on.square")
    ]

    /// How much of the filled twin shows through. A template image keeps its alpha channel, so the
    /// wash still tints from `Theme.current` like any other glyph rather than baking a color.
    private static let composedFillAlpha: CGFloat = 0.25

    private static func compose(
        _ pair: (outline: String, filled: String), config: NSImage.SymbolConfiguration
    ) -> NSImage? {
        guard
            let outline = NSImage(systemSymbolName: pair.outline, accessibilityDescription: nil)?
                .withSymbolConfiguration(config),
            let filled = NSImage(systemSymbolName: pair.filled, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        else { return nil }
        let bounds = NSRect(origin: .zero, size: outline.size)
        let composed = NSImage(size: outline.size)
        composed.lockFocus()
        filled.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: composedFillAlpha)
        outline.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        composed.unlockFocus()
        composed.isTemplate = true
        return composed
    }

    /// The box a brand mark needs to draw the same ink height as an SF Symbol at `pointSize`.
    ///
    /// The proper Git logo (the bundled `git` brand mark), sized as a small inline badge. Shared by
    /// the ⌘P picker and the Settings → Workspaces list to mark a workspace whose folder is a repo,
    /// so the two never drift. A template image, so the caller tints it like any SF Symbol.
    static func gitBadge(pointSize: CGFloat = 12) -> NSImage? {
        guard let image = BrandMark.image("git") else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }
}
