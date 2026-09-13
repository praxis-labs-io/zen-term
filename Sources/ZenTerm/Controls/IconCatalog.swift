import AppKit

// Outline symbols only: a filled symbol outweighs the line-art brand marks sharing its picker row.
enum IconCatalog {
    static let defaultSymbol = "square.on.square"

    struct Section {
        let title: String
        let symbols: [String]
    }

    // A multiple of 8, so the picker grid has no hole before the brands section (`IconCatalogTests`).
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

    // Last, so its short final row reads as the end of the grid.
    static let brands: [String] = [
        "git", "github", "linear", "neovim",
        "vim", "emacs", "helix", "claude",
        "openai", "gemini", "copilot", "opencode",
        "ollama", "docker", "kubernetes", "postgres",
        "sqlite", "slack", "spotify",
    ]

    static let all: [String] = symbols + brands

    static func sections(including selected: String) -> [Section] {
        var sections: [Section] = []
        if !all.contains(selected) {
            sections.append(Section(title: "Current", symbols: [selected]))
        }
        sections.append(Section(title: "Symbols", symbols: symbols))
        sections.append(Section(title: "Brand marks", symbols: brands))
        return sections
    }

    static func displayName(_ symbol: String) -> String {
        if let name = displayOverrides[symbol] { return name }
        let stem = trimmingFillSuffix(symbol)
        let spaced = stem.replacingOccurrences(of: ".", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private static func trimmingFillSuffix(_ symbol: String) -> String {
        for suffix in [".fill", ".filled"] where symbol.hasSuffix(suffix) {
            return String(symbol.dropLast(suffix.count))
        }
        return symbol
    }

    private static let displayOverrides: [String: String] = [
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
        "envelope": "Email",
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
        "square.fill.on.square": "Float",
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
        "htop": "htop",
        "slack": "Slack",
        "spotify": "Spotify",
    ]

    // SF Symbols resolve first, so a brand mark name must never collide with a real symbol.
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

    // Marks carry no internal padding, so they need a slightly larger box to match the symbols.
    static let brandNudge: CGFloat = 1.5

    static func gitBadge(pointSize: CGFloat = 12) -> NSImage? {
        guard let image = BrandMark.image("git") else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }
}
