import CoreGraphics
import Foundation
import TerminalKit

/// Parses `~/.config/zen-term/config` (ghostty-flavored `key = value`, plus repeatable
/// `float =` / `keybind =` lines) into a `GeneralConfig`. Best-effort, symmetric with
/// `GhosttyThemeParser`: unknown keys are ignored, a malformed value falls back to the
/// corresponding `fallback` field, and an out-of-range number is clamped to the nearest
/// valid extreme — every adjustment logs one warning, nothing ever throws.
enum GeneralConfigParser {
    static func parse(_ text: String, fallback: GeneralConfig) -> GeneralConfig {
        var config = fallback
        var floats: [ToolFloat] = []
        var keybinds: [(Chord, KeyInterceptor.ReservedChord)] = []

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
            case "font-family":
                if !value.isEmpty { config.fontName = value }
            case "font-size":
                if let n = parseDouble(value, key) { config.fontSize = CGFloat(clamp(n, 6, 72, key)) }
            case "cursor-style":
                if let style = parseCursorStyle(value) { config.cursorStyle = style }
            case "cursor-style-blink":
                if let b = parseBool(value, key) { config.cursorBlink = b }
            case "cursor-thickness":
                if let n = parseDouble(value, key) { config.cursorThickness = Int(clamp(n, 1, 12, key)) }
            case "macos-option-as-alt":
                if let b = parseBool(value, key) { config.optionAsAlt = b }
            case "scroll-multiplier":
                if let n = parseDouble(value, key) { config.scrollMultiplier = clamp(n, 0.1, 10, key) }
            case "backdrop-alpha":
                if let n = parseDouble(value, key) { config.backdropAlpha = CGFloat(clamp(n, 0, 1, key)) }
            case "window-gutter":
                if let n = parseDouble(value, key) { config.windowGutter = CGFloat(clamp(n, 0, 64, key)) }
            case "pane-gap":
                if let n = parseDouble(value, key) { config.panelGap = CGFloat(clamp(n, 0, 64, key)) }
            case "bottom-drawer-fraction":
                if let n = parseDouble(value, key) { config.bottomDrawerFraction = CGFloat(clamp(n, 0.1, 0.9, key)) }
            case "right-drawer-fraction":
                if let n = parseDouble(value, key) { config.rightDrawerFraction = CGFloat(clamp(n, 0.1, 0.9, key)) }
            case "drawer-resize-step":
                if let n = parseDouble(value, key) { config.drawerResizeStep = CGFloat(clamp(n, 4, 400, key)) }
            case "max-drawer-fraction":
                if let n = parseDouble(value, key) { config.maxDrawerFraction = CGFloat(clamp(n, 0.3, 0.95, key)) }
            case "reduce-motion":
                if let r = parseReduceMotion(value) { config.reduceMotion = r }
            case "agent-notifications":
                if let b = parseBool(value, key) { config.agentNotifications = b }
            case "shell":
                if !value.isEmpty { config.shell = value }
            case "shell-args":
                config.shellArgs = value.split(whereSeparator: \.isWhitespace).map(String.init)
            case "editor":
                if !value.isEmpty { config.editor = value }
            case "ai":
                if !value.isEmpty { config.ai = value }
            case "float":
                if let float = ToolFloatParser.parse(value) {
                    floats.removeAll { $0.id == float.id }  // last declaration of an id wins
                    floats.append(float)
                }
            case "keybind":
                if let pair = KeybindParser.parse(value) {
                    keybinds.append(pair)
                } else {
                    NSLog("GeneralConfig: unparseable keybind line `\(value)` — ignored")
                }
            default:
                continue
            }
        }

        config.floats = floats
        config.keymap = KeymapAssembler.assemble(floats: floats, keybinds: keybinds)
        return config
    }

    private static func parseBool(_ value: String, _ key: String) -> Bool? {
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default:
            NSLog("GeneralConfig: `\(key)` expected true/false, got `\(value)` — using default")
            return nil
        }
    }

    private static func parseDouble(_ value: String, _ key: String) -> Double? {
        // `Double("nan")`/`"inf"` parse successfully but poison clamp() (min/max propagate NaN)
        // and would trap in `Int(nan)` — reject non-finite so nothing can crash the load.
        guard let n = Double(value), n.isFinite else {
            NSLog("GeneralConfig: `\(key)` expected a finite number, got `\(value)` — using default")
            return nil
        }
        return n
    }

    private static func parseCursorStyle(_ value: String) -> TerminalBehavior.CursorStyle? {
        switch value.lowercased() {
        case "block": return .block
        case "bar": return .bar
        case "underline": return .underline
        default:
            NSLog("GeneralConfig: `cursor-style` expected block/bar/underline, got `\(value)` — using default")
            return nil
        }
    }

    private static func parseReduceMotion(_ value: String) -> GeneralConfig.ReduceMotion? {
        switch value.lowercased() {
        case "system": return .system
        case "on": return .on
        case "off": return .off
        default:
            NSLog("GeneralConfig: `reduce-motion` expected system/on/off, got `\(value)` — using default")
            return nil
        }
    }

    /// Clamp a right-typed value to `[lower, upper]`, logging once if it had to move.
    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double, _ key: String) -> Double {
        let clamped = min(max(value, lower), upper)
        if clamped != value {
            NSLog("GeneralConfig: `\(key)` \(value) out of range [\(lower), \(upper)] — clamped to \(clamped)")
        }
        return clamped
    }
}
