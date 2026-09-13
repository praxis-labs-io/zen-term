import AppKit
import TerminalKit

final class SettingsTerminalSection: SettingsFormSection {
    override var navTitle: String { "Terminal" }

    private static let cursorStyles: [TerminalBehavior.CursorStyle] = [.block, .bar, .underline]

    private var shaderTokens: [String?] = []
    private weak var shaderDropdown: Dropdown?

    override func populate() {
        addGroup("Font") {
            self.addTextRow(
                key: "font-family", caption: "Font family", blurb: "Terminal font",
                placeholder: GeneralConfig.builtIn.fontName, read: { $0.fontName }, width: 200)
            self.addNumericRow(
                key: "font-size", caption: "Font size", blurb: "Point size",
                range: SessionFontSize.range, read: { $0.fontSize }, width: 64)
            self.addSegmentedRow(
                key: "font-thicken", caption: "Thicken", blurb: "Heavier terminal text",
                options: ["On", "Off"], read: { $0.fontThicken ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
        }
        addGroup("Background") {
            self.addNumericRow(
                key: "background-alpha", caption: "Background alpha",
                blurb: "Terminal background translucency", range: 0...1,
                read: { CGFloat($0.backgroundAlpha) }, width: 64)
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
            self.addShaderRow()
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
            self.addSegmentedRow(
                key: "tab-inherit-cwd", caption: "Start directory",
                blurb: "Where a new tab or window opens",
                options: ["Home", "Current pane"], read: { $0.tabInheritCWD ? 1 : 0 },
                token: { LayoutFormat.boolToken($0 == 1) }, notifiesOnReselect: false)
        }
        addGroup("Workspace") {
            self.addTextRow(
                key: "editor", caption: "Editor", blurb: "Editor for the Editor + AI + Shell preset",
                placeholder: GeneralConfig.defaultEditor, read: { $0.editor ?? "" }, width: 200)
            self.addTextRow(
                key: "ai", caption: "AI", blurb: "AI tool for the Editor + AI + Shell preset",
                placeholder: GeneralConfig.defaultAI, read: { $0.ai ?? "" }, width: 200)
        }
    }

    /// Static so the stored read closure doesn't retain the section.
    private static func cursorStyleIndex(_ c: GeneralConfig) -> Int {
        cursorStyles.firstIndex(of: c.cursorStyle) ?? 0
    }

    private func addShaderRow() {
        shaderTokens = [nil] + ShaderCatalog.bundled.map { $0.token }
        let selected = currentShaderIndex()
        let dropdown = Dropdown(items: shaderItems(selected: selected), selectedIndex: selected) {
            [weak self] index in self?.selectShader(index)
        }
        shaderDropdown = dropdown

        addCustomRow(
            key: "cursor-shader", caption: "Cursor shader", description: "Cursor animations. GPU intensive.",
            control: dropdown, focusStop: dropdown, controlNote: nil, width: 220,
            refresh: { [weak self] in self?.refreshShaderRow() })
    }

    private func shaderItems(selected: Int) -> [DropdownItem] {
        shaderTokens.enumerated().map { index, token in
            DropdownItem(
                title: token.map(ShaderCatalog.displayName) ?? "Off",
                group: nil, note: nil, isSelected: index == selected)
        }
    }

    private func currentShaderIndex() -> Int {
        shaderTokens.firstIndex(of: Self.currentShaderToken()) ?? 0
    }

    private func selectShader(_ index: Int) {
        guard shaderTokens.indices.contains(index) else { return }
        if let token = shaderTokens[index] {
            write("cursor-shader", token, row: "cursor-shader")
        } else {
            writeOrRemove("cursor-shader", nil, row: "cursor-shader")
        }
    }

    private func refreshShaderRow() {
        let selected = currentShaderIndex()
        shaderDropdown?.setItems(shaderItems(selected: selected), selectedIndex: selected)
    }

    /// Static so the stored read closure doesn't retain the section.
    private static func currentShaderToken() -> String? {
        GeneralConfig.current.cursorShader.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        }
    }
}
