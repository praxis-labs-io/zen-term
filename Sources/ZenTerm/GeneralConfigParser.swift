import AppLog
import CoreGraphics
import Foundation
import TerminalKit

/// Parses `~/.config/zen-term/config` (ghostty-flavored `key = value`, plus repeatable
/// `float =` / `keybind =` lines) into a `GeneralConfig`. Best-effort, symmetric with
/// `GhosttyThemeParser`: unknown keys are ignored, a malformed value falls back to the
/// corresponding `fallback` field, and an out-of-range number is clamped to the nearest
/// valid extreme — every adjustment logs one warning AND collects a `ConfigDiagnostic` so a
/// Settings row can show it in place (ZEN-7), and nothing ever throws.
enum GeneralConfigParser {
    @MainActor
    static func parse(_ text: String, fallback: GeneralConfig) -> GeneralConfig {
        var config = fallback
        var floats: [ToolFloat] = []
        var floatLineIndex = 0
        var keybinds: [KeybindParser.Line] = []
        // The non-keybind diagnostics collected as scalars/enums/floats are read; the keybind ones
        // come from `KeymapAssembler` below and are merged in at the end.
        var diagnostics: [ConfigDiagnostic] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = ConfigText.stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let equals = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))

            switch key {
            case "theme":
                if !value.isEmpty { config.themeName = value }
            case "accent-color":
                if let slot = parseAccentSlot(value, &diagnostics) { config.accentColor = slot }
            case "font-family":
                if !value.isEmpty { config.fontName = value }
            case "font-size":
                if let n = parseDouble(value, key, &diagnostics) {
                    // The same range ⌘+ / ⌘- step within — one concept, one set of bounds, whichever
                    // way the user reaches it.
                    config.fontSize = CGFloat(
                        clamp(
                            n, Double(SessionFontSize.range.lowerBound),
                            Double(SessionFontSize.range.upperBound), key, &diagnostics))
                }
            case "cursor-style":
                if let style = parseCursorStyle(value, &diagnostics) { config.cursorStyle = style }
            case "cursor-style-blink":
                if let b = parseBool(value, key, &diagnostics) { config.cursorBlink = b }
            case "cursor-thickness":
                if let n = parseDouble(value, key, &diagnostics) {
                    config.cursorThickness = Int(clamp(n, 1, 12, key, &diagnostics))
                }
            case "macos-option-as-alt":
                if let b = parseBool(value, key, &diagnostics) { config.optionAsAlt = b }
            case "scroll-multiplier":
                if let n = parseDouble(value, key, &diagnostics) {
                    config.scrollMultiplier = clamp(n, 0.1, 10, key, &diagnostics)
                }
            case "cursor-shader":
                // Single-select: store the raw bundled-shader name (last line wins). ConfigLoader
                // resolves it to a bundled path (the parser stays text-pure and off the filesystem).
                if !value.isEmpty { config.cursorShader = value }
            case "background-alpha":
                if let n = parseDouble(value, key, &diagnostics) {
                    config.backgroundAlpha = clamp(n, 0, 1, key, &diagnostics)
                }
            case "window-chrome":
                if let b = parseBool(value, key, &diagnostics) { config.windowChrome = b }
            case "backdrop-alpha":
                if let n = parseDouble(value, key, &diagnostics) {
                    config.backdropAlpha = CGFloat(clamp(n, 0, 1, key, &diagnostics))
                }
            case "window-gutter":
                if let n = parseDouble(value, key, &diagnostics) {
                    config.windowGutter = CGFloat(clamp(n, 0, 64, key, &diagnostics))
                }
            case "pane-gap":
                if let n = parseDouble(value, key, &diagnostics) {
                    config.panelGap = CGFloat(clamp(n, 0, 64, key, &diagnostics))
                }
            case "bottom-drawer-fraction":
                if let n = parseDouble(value, key, &diagnostics) {
                    config.bottomDrawerFraction = CGFloat(clamp(n, 0.1, 0.9, key, &diagnostics))
                }
            case "right-drawer-fraction":
                if let n = parseDouble(value, key, &diagnostics) {
                    config.rightDrawerFraction = CGFloat(clamp(n, 0.1, 0.9, key, &diagnostics))
                }
            case "drawer-resize-step":
                if let n = parseDouble(value, key, &diagnostics) {
                    config.drawerResizeStep = CGFloat(clamp(n, 4, 400, key, &diagnostics))
                }
            case "max-drawer-fraction":
                if let n = parseDouble(value, key, &diagnostics) {
                    config.maxDrawerFraction = CGFloat(clamp(n, 0.3, 0.95, key, &diagnostics))
                }
            case "hide-toolbar-buttons":
                config.hiddenToolbarButtons = parseHiddenToolbarButtons(value, &diagnostics)
            case "reduce-motion":
                if let r = parseReduceMotion(value, &diagnostics) { config.reduceMotion = r }
            case "diff-layout":
                if let d = parseDiffLayout(value, &diagnostics) { config.diffLayout = d }
            case "agent-notifications":
                if let b = parseBool(value, key, &diagnostics) { config.agentNotifications = b }
            case "automatic-update-checks":
                if let b = parseBool(value, key, &diagnostics) { config.automaticUpdateChecks = b }
            case "debug":
                if let b = parseBool(value, key, &diagnostics) { config.debug = b }
            case "shell":
                if !value.isEmpty { config.shell = value }
            case "shell-args":
                config.shellArgs = value.split(whereSeparator: \.isWhitespace).map(String.init)
            case "editor":
                if !value.isEmpty { config.editor = value }
            case "ai":
                if !value.isEmpty { config.ai = value }
            case "float":
                let (float, floatDiagnostics) = ToolFloatParser.parseLine(value, fallbackOrder: floatLineIndex)
                if let float, ToolFloat.isBuiltIn(float.id) {
                    // A built-in's id keys its toolbar button, its Shortcuts row, its palette entry
                    // and its default chord. Shadowing it would repoint that chord at the user's
                    // command while every one of those still said the built-in's name, so the line
                    // is refused where the user can see it instead.
                    Log.warning(
                        "GeneralConfig: float `\(float.id)` uses a reserved name: ignored",
                        category: .keybinds)
                    diagnostics.append(
                        ConfigDiagnostic(
                            scope: .toolFloat(label: float.title),
                            problem: .floatReservedID(float.id)))
                } else if let float {
                    floats.removeAll { $0.id == float.id }  // last declaration of an id wins
                    floats.append(float)
                }
                diagnostics.append(contentsOf: floatDiagnostics)
                // Counts every float line, parsed or not, so a dropped line leaves a gap rather than
                // shifting the floats below it out of file order.
                floatLineIndex += 1
            case "keybind":
                if let line = KeybindParser.parse(value) {
                    keybinds.append(line)
                } else {
                    warnUnparseableKeybind(value, &diagnostics)
                }
            default:
                continue
            }
        }

        let ordered = sortedByOrder(floats)
        config.floats = ordered
        let assembled = KeymapAssembler.assemble(floats: ordered, keybinds: keybinds)
        config.keymap = assembled.map
        config.unboundActions = assembled.unbound
        config.configDiagnostics = diagnostics + assembled.diagnostics
        return config
    }

    /// Toolbar / palette / Settings order — one array, so all three surfaces stay in agreement. The key
    /// is the config `order:` with the float's line order as the tie-break: Swift's sort isn't stable,
    /// so two floats sharing an `order:` would otherwise be free to shuffle between launches.
    private static func sortedByOrder(_ floats: [ToolFloat]) -> [ToolFloat] {
        floats.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
    }

    /// A keybind line that didn't parse. `toggle_lazygit` gets a named migration warning —
    /// ZEN-140 removed the built-in lazygit, and "unparseable" would hide what changed. The
    /// suggested replacement echoes the full documented parity recipe (icon/title/height match
    /// the old built-in card) and keeps the chord from the user's own dropped line, so following
    /// the log verbatim reproduces what they had. Exact-match on the action left of `=` (the same
    /// split `KeybindParser` uses), so a typo like `toggle_lazygit_old` still reads unparseable.
    ///
    /// Only the generic case collects a `ConfigDiagnostic`: the lazygit branch is a transitional
    /// migration whose whole value is the multi-line recipe, which a terse toast would lose — it
    /// stays log-only on purpose.
    private static func warnUnparseableKeybind(_ value: String, _ diagnostics: inout [ConfigDiagnostic]) {
        let equals = value.firstIndex(of: "=")
        let action = (equals.map { value[..<$0] } ?? Substring(value))
            .trimmingCharacters(in: .whitespaces)
        guard action == "toggle_lazygit" else {
            Log.warning("GeneralConfig: unparseable keybind line `\(value)` — ignored", category: .keybinds)
            diagnostics.append(ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine(value)))
            return
        }
        let bound = equals.map {
            value[value.index(after: $0)...].trimmingCharacters(in: .whitespaces)
        }
        let chord = bound.flatMap { $0.isEmpty ? nil : $0 } ?? "cmd+g"
        Log.warning(
            "GeneralConfig: `toggle_lazygit` was removed — lazygit is a regular tool float now; "
                + "replace this keybind with: float = command:\"lazygit\" "
                + "key:\(chord) git:true persist:dir icon:git title:\"Open Lazygit\" "
                + "height:0.78 — ignored",
            category: .config)
    }

    private static func parseBool(
        _ value: String, _ key: String, _ diagnostics: inout [ConfigDiagnostic]
    ) -> Bool? {
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default:
            Log.warning(
                "GeneralConfig: `\(key)` expected true/false, got `\(value)` — using default",
                category: .config)
            diagnostics.append(invalid(key, got: value, expected: "true or false"))
            return nil
        }
    }

    private static func parseDouble(
        _ value: String, _ key: String, _ diagnostics: inout [ConfigDiagnostic]
    ) -> Double? {
        // `Double("nan")`/`"inf"` parse successfully but poison clamp() (min/max propagate NaN)
        // and would trap in `Int(nan)` — reject non-finite so nothing can crash the load.
        guard let n = Double(value), n.isFinite else {
            Log.warning(
                "GeneralConfig: `\(key)` expected a finite number, got `\(value)` — using default",
                category: .config)
            diagnostics.append(invalid(key, got: value, expected: "a number"))
            return nil
        }
        return n
    }

    private static func parseCursorStyle(
        _ value: String, _ diagnostics: inout [ConfigDiagnostic]
    ) -> TerminalBehavior.CursorStyle? {
        switch value.lowercased() {
        case "block": return .block
        case "bar": return .bar
        case "underline": return .underline
        default:
            Log.warning(
                "GeneralConfig: `cursor-style` expected block/bar/underline, got `\(value)` — using default",
                category: .config)
            diagnostics.append(invalid("cursor-style", got: value, expected: "block, bar, or underline"))
            return nil
        }
    }

    /// The 16 ANSI hue names. The expected-value list is built from `AccentSlot.allCases` rather
    /// than spelled out, so a new slot can't leave the diagnostic naming a stale set.
    private static func parseAccentSlot(
        _ value: String, _ diagnostics: inout [ConfigDiagnostic]
    ) -> AccentSlot? {
        if let slot = AccentSlot(rawValue: value.lowercased()) { return slot }
        let expected = AccentSlot.allCases.map(\.rawValue).joined(separator: ", ")
        Log.warning(
            "GeneralConfig: `accent-color` got `\(value)` — using default",
            category: .config)
        diagnostics.append(invalid("accent-color", got: value, expected: expected))
        return nil
    }

    /// The `hide-toolbar-buttons` list: comma-separated `ToolbarButton` slugs. Empty segments
    /// (trailing/doubled commas) pass silently; an unknown slug is dropped with a diagnostic while
    /// the known slugs on the same line still apply. The expected-value list is built from
    /// `ToolbarButton.allCases` rather than spelled out, mirroring `parseAccentSlot`.
    private static func parseHiddenToolbarButtons(
        _ value: String, _ diagnostics: inout [ConfigDiagnostic]
    ) -> Set<ToolbarButton> {
        var hidden: Set<ToolbarButton> = []
        for raw in value.split(separator: ",") {
            let slug = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !slug.isEmpty else { continue }
            guard let button = ToolbarButton(rawValue: slug) else {
                let expected = ToolbarButton.allCases.map(\.rawValue).joined(separator: ", ")
                Log.warning(
                    "GeneralConfig: `hide-toolbar-buttons` got unknown button `\(slug)` — ignored",
                    category: .config)
                diagnostics.append(
                    ConfigDiagnostic(
                        scope: .setting(key: "hide-toolbar-buttons"),
                        problem: .ignoredListItem(got: slug, expected: expected)))
                continue
            }
            hidden.insert(button)
        }
        return hidden
    }

    private static func parseReduceMotion(
        _ value: String, _ diagnostics: inout [ConfigDiagnostic]
    ) -> GeneralConfig.ReduceMotion? {
        switch value.lowercased() {
        case "system": return .system
        case "on": return .on
        case "off": return .off
        default:
            Log.warning(
                "GeneralConfig: `reduce-motion` expected system/on/off, got `\(value)` — using default",
                category: .config)
            diagnostics.append(invalid("reduce-motion", got: value, expected: "system, on, or off"))
            return nil
        }
    }

    private static func parseDiffLayout(
        _ value: String, _ diagnostics: inout [ConfigDiagnostic]
    ) -> GeneralConfig.DiffLayout? {
        switch value.lowercased() {
        case "side-by-side": return .sideBySide
        case "inline": return .inline
        default:
            Log.warning(
                "GeneralConfig: `diff-layout` expected side-by-side/inline, got `\(value)` — using default",
                category: .config)
            diagnostics.append(invalid("diff-layout", got: value, expected: "side-by-side or inline"))
            return nil
        }
    }

    /// Clamp a right-typed value to `[lower, upper]`, logging + collecting a diagnostic once if it
    /// had to move.
    private static func clamp(
        _ value: Double, _ lower: Double, _ upper: Double, _ key: String,
        _ diagnostics: inout [ConfigDiagnostic]
    ) -> Double {
        let clamped = min(max(value, lower), upper)
        if clamped != value {
            Log.warning(
                "GeneralConfig: `\(key)` \(value) out of range [\(lower), \(upper)] — clamped to \(clamped)",
                category: .config)
            diagnostics.append(
                ConfigDiagnostic(
                    scope: .setting(key: key),
                    problem: .clamped(value: numberText(value), to: numberText(clamped))))
        }
        return clamped
    }

    private static func invalid(_ key: String, got: String, expected: String) -> ConfigDiagnostic {
        ConfigDiagnostic(scope: .setting(key: key), problem: .invalidValue(got: got, expected: expected))
    }

    /// A config number without a trailing `.0` (`200`, not `200.0`; `0.95` stays `0.95`) — the form
    /// the value reads as in the file, so a diagnostic names it the way the user typed it.
    private static func numberText(_ value: Double) -> String { String(format: "%g", value) }
}
