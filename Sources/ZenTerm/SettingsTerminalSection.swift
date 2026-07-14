import AppKit
import TerminalKit

/// The Terminal settings section: font, cursor, input, and shell knobs. A subclass of
/// `SettingsFormSection` — it only declares its groups. Font/cursor/input apply live to every open
/// surface; shell/shell-args still apply to new tabs only, since a running shell process can't be
/// hot-swapped.
final class SettingsTerminalSection: SettingsFormSection {
    override var navTitle: String { "Terminal" }

    private static let cursorStyles: [TerminalBehavior.CursorStyle] = [.block, .bar, .underline]

    override func populate() {
        addGroup("Font") {
            self.addTextRow(
                key: "font-family", caption: "Font family", blurb: "Terminal font",
                placeholder: GeneralConfig.builtIn.fontName, read: { $0.fontName }, width: 200)
            self.addNumericRow(
                key: "font-size", caption: "Font size", blurb: "Point size",
                range: 6...72, read: { $0.fontSize }, width: 64)
        }
        addGroup("Cursor") {
            self.addSegmentedRow(
                key: "cursor-style", caption: "Style", blurb: "Cursor shape",
                options: ["Block", "Bar", "Underline"], read: { Self.cursorStyleIndex($0) },
                token: { LayoutFormat.cursorStyleToken(Self.cursorStyles[$0]) }, notifiesOnReselect: false)
            self.addSegmentedRow(
                key: "cursor-style-blink", caption: "Blink", blurb: "Blink the cursor",
                options: ["On", "Off"], read: { $0.cursorBlink ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
            self.addNumericRow(
                key: "cursor-thickness", caption: "Thickness", blurb: "Bar/underline thickness in px",
                range: 1...12, read: { CGFloat($0.cursorThickness) }, width: 64, integer: true)
        }
        addGroup("Input") {
            self.addSegmentedRow(
                key: "macos-option-as-alt", caption: "Option as Alt", blurb: "Send Option as Meta",
                options: ["On", "Off"], read: { $0.optionAsAlt ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
            self.addNumericRow(
                key: "scroll-multiplier", caption: "Scroll speed", blurb: "Scroll wheel multiplier",
                range: 0.1...10, read: { CGFloat($0.scrollMultiplier) }, width: 64)
        }
        addGroup("Shell") {
            self.addTextRow(
                key: "shell", caption: "Shell", blurb: "Login shell (new tabs)", placeholder: "login shell",
                read: { $0.shell ?? "" }, width: 200)
            self.addTextRow(
                key: "shell-args", caption: "Shell args", blurb: "Passed to the shell (new tabs)",
                placeholder: "optional", read: { LayoutFormat.joinArgs($0.shellArgs) }, width: 200)
        }
        addGroup("Workspace") {
            self.addTextRow(
                key: "editor", caption: "Editor", blurb: "Editor for the Editor + AI + Shell preset",
                placeholder: "nvim", read: { $0.editor ?? "" }, width: 200)
            self.addTextRow(
                key: "ai", caption: "AI", blurb: "AI tool for the Editor + AI + Shell preset",
                placeholder: "claude", read: { $0.ai ?? "" }, width: 200)
        }
    }

    /// Cursor style shown by index; static so the `read` closure the base stores per row doesn't
    /// capture `self` (which would retain-cycle through the section's `refreshers`).
    private static func cursorStyleIndex(_ c: GeneralConfig) -> Int {
        cursorStyles.firstIndex(of: c.cursorStyle) ?? 0
    }
}
