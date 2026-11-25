import AppKit
import TerminalKit

// The chip a pane's program shows, in its brand's colors or the theme's; a palette group's, in its purpose tint.
struct ProcessIcon: Equatable {
    enum Look: Equatable {
        case brand(fill: TerminalColor, glyph: TerminalColor)
        case artwork(fill: TerminalColor)
        case neutral
        case purpose(AccentSlot)
        // The one look that may draw an SF Symbol: a tool float's own icon picker name.
        case catalog(AccentSlot)
    }

    let name: String
    let mark: String
    let look: Look
    // A mark drawn with its own margin, or wider than tall, reads the wrong size in the shared glyph box.
    let scale: CGFloat

    var image: NSImage? {
        switch look {
        case .artwork: return BrandMark.artwork(mark)
        case .catalog: return IconCatalog.image(mark, weight: .regular)
        case .brand, .neutral, .purpose: return BrandMark.image(mark)
        }
    }

    static let shell = neutral("Shell", "terminal")
    static let unknown = neutral("Program", "binary")
    static let unknownAgent = neutral("Agent", "bot")
    static let worktree = neutral("Worktree", "git-branch")

    static let workspace = purpose("Workspace", "folder", .magenta)
    static let tab = purpose("Tab", "panel-top", .cyan)
    static let pane = purpose("Pane", "columns-2", .yellow)
    static let terminal = purpose("Terminal", "terminal", .green)
    static let window = purpose("Window", "app-window", .blue)
    static let tool = purpose("Tool", "hammer", toolTint)
    static let app = neutral("App", "settings")

    // Floats are terminals too, so the Tools group shares the Terminal hue.
    private static let toolTint = AccentSlot.green

    static func toolFloat(_ float: ToolFloat) -> ProcessIcon {
        ProcessIcon(name: float.title, mark: float.icon, look: .catalog(toolTint), scale: 1)
    }

    private static func purpose(_ name: String, _ mark: String, _ hue: AccentSlot) -> ProcessIcon {
        ProcessIcon(name: name, mark: mark, look: .purpose(hue), scale: lucideScale)
    }

    static func forProgram(_ program: String?) -> ProcessIcon {
        guard let program = program?.lowercased(), !program.isEmpty else { return shell }
        return byProgram[program] ?? byProgram[ProcessArguments.withoutVersion(program)] ?? unknown
    }

    static func forCommand(_ arguments: [String]) -> ProcessIcon {
        guard let program = arguments.first.flatMap(ProcessArguments.programName(from:)) else { return unknown }
        if let script = ProcessArguments.scriptName(in: arguments), let icon = byProgram[script.lowercased()] {
            return icon
        }
        return forProgram(program)
    }

    // An agent names itself in words (`Claude Code`), so any one of them can be its program.
    static func forAgent(_ name: String) -> ProcessIcon {
        let words = Set(name.lowercased().split { !$0.isLetter }.map(String.init))
        return agents.first { words.contains($0.program) }?.icon ?? unknownAgent
    }

    // Lucide draws inside a margin the brand marks lack, so its glyphs take a slightly larger box.
    private static let lucideScale: CGFloat = 1.05
    // A brand mark fills its box edge to edge, so it sits a touch inside it to keep air around it in the chip.
    private static let brandScale: CGFloat = 0.9

    private static func neutral(_ name: String, _ mark: String) -> ProcessIcon {
        ProcessIcon(name: name, mark: mark, look: .neutral, scale: lucideScale)
    }

    private static func brand(_ name: String, _ mark: String, _ fill: UInt32, _ glyph: UInt32, scale: CGFloat = 1)
        -> ProcessIcon
    {
        ProcessIcon(name: name, mark: mark, look: .brand(fill: rgb(fill), glyph: rgb(glyph)), scale: scale * brandScale)
    }

    private static func artwork(_ name: String, _ mark: String, _ fill: UInt32) -> ProcessIcon {
        ProcessIcon(name: name, mark: mark, look: .artwork(fill: rgb(fill)), scale: brandScale)
    }

    private static func rgb(_ hex: UInt32) -> TerminalColor {
        TerminalColor(red: UInt8(hex >> 16 & 0xFF), green: UInt8(hex >> 8 & 0xFF), blue: UInt8(hex & 0xFF))
    }

    private static let agents: [(program: String, icon: ProcessIcon)] = [
        ("claude", brand("Claude Code", "claude", 0xD97757, 0xFFFFFF)),
        ("codex", brand("Codex", "openai", 0xFFFFFF, 0x0D0D0D)),
        ("gemini", artwork("Gemini", "gemini-color", 0xFFFFFF)),
        ("copilot", brand("Copilot", "copilot", 0x0D1117, 0xFFFFFF)),
        ("opencode", brand("OpenCode", "opencode", 0x0A0A0A, 0xF1ECEC, scale: 0.9)),
        ("pi", artwork("Pi", "pi-agent", 0x141414)),
        ("ollama", brand("Ollama", "ollama", 0xFFFFFF, 0x000000)),
    ]

    // Brand colors are the one place the chrome names a color: they belong to the brand, never the theme.
    private static let programs: [(names: [String], icon: ProcessIcon)] = [
        (["nvim"], brand("Neovim", "neovim", 0x57A143, 0xFFFFFF)),
        (["vim", "vi", "view"], brand("Vim", "vim", 0x019733, 0xFFFFFF)),
        (["emacs", "emacsclient"], brand("Emacs", "emacs", 0x7F5AB6, 0xFFFFFF)),
        (["hx", "helix"], brand("Helix", "helix", 0x281733, 0xFFFFFF)),
        (["git", "lazygit", "tig", "gitui"], brand("Git", "git", 0xF05032, 0xFFFFFF)),
        (["gh"], brand("GitHub", "github", 0x181717, 0xFFFFFF)),
        (["docker", "docker-compose", "lazydocker"], brand("Docker", "docker", 0x2496ED, 0xFFFFFF)),
        (["podman"], brand("Podman", "podman", 0x892CA0, 0xFFFFFF)),
        (["kubectl", "k9s", "kubectx", "minikube"], brand("Kubernetes", "kubernetes", 0x326CE5, 0xFFFFFF)),
        (["terraform"], brand("Terraform", "terraform", 0x844FBA, 0xFFFFFF)),
        (["psql", "pgcli", "postgres"], brand("PostgreSQL", "postgres", 0x4169E1, 0xFFFFFF)),
        (["mysql", "mycli"], brand("MySQL", "mysql", 0x00546B, 0xFFFFFF)),
        (["sqlite3", "litecli"], brand("SQLite", "sqlite", 0x003B57, 0xFFFFFF)),
        (["redis-cli", "redis-server"], brand("Redis", "redis", 0xFF4438, 0xFFFFFF)),
        (["python", "ipython", "bpython"], brand("Python", "python", 0x3776AB, 0xFFD43B)),
        (["node"], brand("Node.js", "nodedotjs", 0x5FA04E, 0xFFFFFF)),
        (["npm", "npx"], brand("npm", "npm", 0xCB3837, 0xFFFFFF)),
        (["pnpm", "pnpx"], brand("pnpm", "pnpm", 0x222222, 0xF69220, scale: 0.9)),
        (["yarn"], brand("Yarn", "yarn", 0x2C8EBF, 0xFFFFFF)),
        (["bun", "bunx"], brand("Bun", "bun", 0xFBF0DF, 0x14151A)),
        (["deno"], brand("Deno", "deno", 0x000000, 0xFFFFFF)),
        (["cargo", "rustc", "rustup"], brand("Rust", "rust", 0xB7410E, 0xFFFFFF)),
        (["go"], brand("Go", "go", 0x00ADD8, 0xFFFFFF, scale: 1.25)),
        (["ruby", "irb", "bundle", "rails", "rake"], brand("Ruby", "ruby", 0xCC342D, 0xFFFFFF)),
        (["swift", "swiftc"], brand("Swift", "swift", 0xF05138, 0xFFFFFF)),
        (["brew"], brand("Homebrew", "homebrew", 0xFBB040, 0x2E2A24)),
        (["tmux"], brand("tmux", "tmux", 0x1BB91F, 0xFFFFFF)),
        (["htop"], brand("htop", "htop", 0x111111, 0x6EE07A)),
        (["linear"], brand("Linear", "linear", 0x222326, 0xF7F8F8)),
        (["spotify_player", "spt"], brand("Spotify", "spotify", 0x121212, 0x1ED760)),
        (["zsh", "bash", "sh", "fish", "nu", "dash", "ksh", "tcsh", "csh", "elvish", "xonsh", "pwsh"], shell),
        (["aider", "amp", "goose", "crush", "cursor-agent", "llm", "aichat", "mods", "qwen"], unknownAgent),
        (["ssh", "mosh", "et", "autossh"], neutral("Remote", "server")),
        (["sleep", "wait", "watch"], neutral("Timer", "hourglass")),
        (["make", "cmake", "ninja", "xcodebuild", "gradle", "mvn", "bazel"], neutral("Build", "hammer")),
        (["pip", "pip3", "pipx", "uv", "poetry", "apt", "apt-get", "gem", "conda"], neutral("Package", "package")),
        (["pytest", "jest", "vitest", "mocha"], neutral("Tests", "flask-conical")),
        (["yazi", "lf", "ranger", "nnn", "broot", "mc"], neutral("Files", "folder")),
        (["fzf", "rg", "fd", "grep", "ag"], neutral("Search", "search")),
        (["less", "more", "man", "bat", "glow"], neutral("Reader", "file-text")),
        (["tail", "journalctl", "lnav"], neutral("Logs", "scroll-text")),
        (["top", "btop", "btm", "glances", "iotop"], neutral("Monitor", "gauge")),
        (["curl", "wget", "http", "https", "xh"], neutral("HTTP", "send")),
        (["zellij", "screen"], neutral("Multiplexer", "columns-2")),
        (["gpg", "pass", "age", "op"], neutral("Secrets", "key-round")),
        (["usql", "duckdb"], neutral("Database", "database")),
        (["nano", "micro", "kak", "pico"], neutral("Editor", "text-cursor-input")),
    ]

    private static let byProgram: [String: ProcessIcon] = Dictionary(
        agents.map { ($0.program, $0.icon) } + programs.flatMap { entry in entry.names.map { ($0, entry.icon) } },
        uniquingKeysWith: { first, _ in first })

    static var allForTesting: [ProcessIcon] {
        [shell, unknown, unknownAgent, worktree] + agents.map(\.icon) + programs.map(\.icon)
    }

    static var programNamesForTesting: [String] { agents.map(\.program) + programs.flatMap(\.names) }
}
