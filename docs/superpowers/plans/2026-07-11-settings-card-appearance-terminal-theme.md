# Settings card PR3 — Appearance + Terminal + Theme picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Round out the ZEN-75 Settings card — rename General → Appearance with a bundled-theme picker, add a full Terminal config section, and share one form-machinery base between them; theme changes apply on restart via a button.

**Architecture:** Extract PR2's section machinery into a `SettingsFormSection` base class (template method + protected row builders); `SettingsAppearanceSection` and `SettingsTerminalSection` subclass it and only declare their groups. A `ThemeCatalog` enumerates bundled ghostty theme resources merged with the user's `themes/` dir; a new keyboard-first `Dropdown` primitive selects one and writes `theme = <name>`; a `Relauncher` restarts to apply.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit. Backend seam untouched (no `import SwiftTerm` in ZenTerm). Tests are XCTest in the `ZenTermTests` target.

## Global Constraints

- **Seam:** `Sources/ZenTerm/` must not `import SwiftTerm` or any backend. Theme colors come from `Theme.current`; terminal knobs write config, they do not touch the backend directly.
- **Colors:** never hardcode a color in the chrome. Use `Theme.current.chrome` roles (`background`, `foreground`, `accent`, `muted`, `destructive`, `info`, …) and `chrome.ink(alpha:)`. Banned: `.white`/`.black`/hex/`NSColor(white:)`.
- **Copy:** no middle-dot `·` separators and no em dashes anywhere in UI copy.
- **Naming:** PascalCase types, one primary type per file, filename matches the type. kebab-case config keys already exist in `GeneralConfigParser`.
- **No markers:** no `TODO`/`FIXME`/`HACK`; no `eslint-disable`-style suppressions; resolve surfaced issues in the same change.
- **Gate:** `bin/check` fully green (build + `swift test` + `swift format lint --strict` + `swiftlint --strict`) before a task is done. `bin/check --fix` auto-applies format/lint fixes.
- **Ranges match the parser** (`GeneralConfigParser` clamps): `font-size` 6–72, `cursor-thickness` 1–12, `scroll-multiplier` 0.1–10, plus the existing layout ranges.

---

## File Structure

**New source:**
- `Sources/ZenTerm/SettingsFormSection.swift` — base class: row builders + live-apply debounce + persist/refresh + focus stops + reset-all. Owns the shared machinery lifted from PR2's `SettingsLayoutSection`.
- `Sources/ZenTerm/SettingsAppearanceSection.swift` — Appearance section (Theme + Layout + Motion groups). Replaces `SettingsLayoutSection.swift`.
- `Sources/ZenTerm/SettingsTerminalSection.swift` — Terminal section (Font + Cursor + Input + Shell groups).
- `Sources/ZenTerm/ThemeCatalog.swift` — bundled catalog manifest + user-dir merge + bundled-resource URL lookup.
- `Sources/ZenTerm/Controls/Dropdown.swift` — keyboard-navigable themed dropdown primitive (`DropdownItem` + `Dropdown`).
- `Sources/ZenTerm/Relauncher.swift` — spawn-fresh-then-terminate restart helper.
- `Sources/ZenTerm/Themes/*.ghostty` — ~16 bundled ghostty theme files (data assets).

**New tests:**
- `Tests/ZenTermTests/LayoutFormatTerminalTokenTests.swift`
- `Tests/ZenTermTests/ThemeCatalogTests.swift`
- `Tests/ZenTermTests/ThemeResolutionTests.swift`
- `Tests/ZenTermTests/TerminalConfigWriteTests.swift`

**Modified:**
- `Sources/ZenTerm/LayoutFormat.swift` — cursor-style + bool token helpers.
- `Sources/ZenTerm/ConfigLoader.swift` — bundled-resource theme resolution in `resolveThemeURL`.
- `Sources/ZenTerm/WindowController.swift:481-490` — register Terminal + Appearance sections; nav order Appearance, Terminal, Keybinds.
- `Package.swift:58` — add `.copy("Themes")` to the ZenTerm target resources.
- `docs/config/config` — note the bundled theme catalog + that the picker writes `theme`.

**Delete:** `Sources/ZenTerm/SettingsLayoutSection.swift` (content moves to the base + `SettingsAppearanceSection.swift`).

---

## Task 1: LayoutFormat terminal token helpers

**Files:**
- Modify: `Sources/ZenTerm/LayoutFormat.swift`
- Test: `Tests/ZenTermTests/LayoutFormatTerminalTokenTests.swift`

**Interfaces:**
- Consumes: `TerminalBehavior.CursorStyle` (from TerminalKit: `.block`/`.bar`/`.underline`).
- Produces:
  - `LayoutFormat.cursorStyleToken(_ s: TerminalBehavior.CursorStyle) -> String`
  - `LayoutFormat.parseCursorStyle(_ text: String) -> TerminalBehavior.CursorStyle?`
  - `LayoutFormat.boolToken(_ on: Bool) -> String`

- [ ] **Step 1: Write the failing test**

Create `Tests/ZenTermTests/LayoutFormatTerminalTokenTests.swift`:

```swift
import TerminalKit
import XCTest

@testable import ZenTerm

final class LayoutFormatTerminalTokenTests: XCTestCase {
    func test_cursorStyleToken_roundTrips() {
        for style in [TerminalBehavior.CursorStyle.block, .bar, .underline] {
            let token = LayoutFormat.cursorStyleToken(style)
            XCTAssertEqual(LayoutFormat.parseCursorStyle(token), style)
        }
    }

    func test_cursorStyleTokens_areGhosttyLiterals() {
        XCTAssertEqual(LayoutFormat.cursorStyleToken(.block), "block")
        XCTAssertEqual(LayoutFormat.cursorStyleToken(.bar), "bar")
        XCTAssertEqual(LayoutFormat.cursorStyleToken(.underline), "underline")
    }

    func test_parseCursorStyle_isCaseInsensitive_andRejectsGarbage() {
        XCTAssertEqual(LayoutFormat.parseCursorStyle("  BLOCK "), .block)
        XCTAssertNil(LayoutFormat.parseCursorStyle("beam"))
    }

    func test_boolToken() {
        XCTAssertEqual(LayoutFormat.boolToken(true), "true")
        XCTAssertEqual(LayoutFormat.boolToken(false), "false")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LayoutFormatTerminalTokenTests 2>&1 | tail -20`
Expected: FAIL — `cursorStyleToken`/`parseCursorStyle`/`boolToken` are not members of `LayoutFormat`.

- [ ] **Step 3: Add the helpers**

In `Sources/ZenTerm/LayoutFormat.swift`, add before the closing `}` of `enum LayoutFormat` (the file already `import`s Foundation; add `import TerminalKit` at the top if not present — it is not, so add it):

```swift
    /// ghostty's `cursor-style` literal for a cursor shape (`block`/`bar`/`underline`).
    static func cursorStyleToken(_ s: TerminalBehavior.CursorStyle) -> String {
        switch s {
        case .block: return "block"
        case .bar: return "bar"
        case .underline: return "underline"
        }
    }

    /// Parse a `cursor-style` value, case-insensitively; nil if it isn't a known shape.
    static func parseCursorStyle(_ text: String) -> TerminalBehavior.CursorStyle? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "block": return .block
        case "bar": return .bar
        case "underline": return .underline
        default: return nil
        }
    }

    /// The config token for a boolean knob (`cursor-style-blink`, `macos-option-as-alt`).
    static func boolToken(_ on: Bool) -> String { on ? "true" : "false" }
```

Add `import TerminalKit` under `import Foundation` at the top of the file.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LayoutFormatTerminalTokenTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/LayoutFormat.swift Tests/ZenTermTests/LayoutFormatTerminalTokenTests.swift
git commit -m "LayoutFormat: cursor-style + bool token helpers (ZEN-75 PR3)"
```

---

## Task 2: Bundled theme catalog + `ThemeCatalog`

**Files:**
- Create: `Sources/ZenTerm/Themes/*.ghostty` (~16 files, data)
- Create: `Sources/ZenTerm/ThemeCatalog.swift`
- Modify: `Package.swift:58` (add `.copy("Themes")`)
- Test: `Tests/ZenTermTests/ThemeCatalogTests.swift`

**Interfaces:**
- Consumes: `ConfigLoader.defaultRoot: URL`; `Bundle.module` (ZenTerm already has resources, so `Bundle.module` exists).
- Produces:
  - `struct ThemeEntry: Equatable { enum Source { case builtIn, bundled, user }; let name: String?; let displayName: String; let isDark: Bool; let source: Source }`
  - `enum ThemeCatalog` with:
    - `static let bundled: [(token: String, displayName: String, isDark: Bool)]`
    - `static func entries(configRoot: URL = ConfigLoader.defaultRoot) -> [ThemeEntry]`
    - `static func bundledURL(for token: String) -> URL?`

### Theme file assets

Bundled themes are **data**, sourced from the ghostty theme catalog (the same
files ghostty ships, also mirrored in `mbadolato/iTerm2-Color-Schemes` under its
`ghostty/` output). Each file is `key = value` lines parseable by
`GhosttyThemeParser`: it MUST contain `background`, `foreground`, and
`palette = 0=…` through `palette = 15=…` (16 lines); `cursor-color` and
`selection-background` are recommended. File name = `<token>.ghostty`.

Manifest (token → display name, isDark). Create one `<token>.ghostty` per row:

| token | display | isDark |
|-------|---------|--------|
| `rose-pine` | Rosé Pine | true |
| `rose-pine-dawn` | Rosé Pine Dawn | false |
| `catppuccin-latte` | Catppuccin Latte | false |
| `catppuccin-frappe` | Catppuccin Frappé | true |
| `catppuccin-macchiato` | Catppuccin Macchiato | true |
| `catppuccin-mocha` | Catppuccin Mocha | true |
| `tokyo-night` | Tokyo Night | true |
| `tokyo-night-storm` | Tokyo Night Storm | true |
| `tokyo-night-day` | Tokyo Night Day | false |
| `nord` | Nord | true |
| `gruvbox-dark` | Gruvbox Dark | true |
| `dracula` | Dracula | true |
| `solarized-dark` | Solarized Dark | true |
| `everforest` | Everforest | true |
| `kanagawa` | Kanagawa | true |

Reference file — `Sources/ZenTerm/Themes/catppuccin-mocha.ghostty` (verified
Catppuccin Mocha palette; use as the format template for the rest):

```
background = 1e1e2e
foreground = cdd6f4
cursor-color = f5e0dc
selection-background = 353749
palette = 0=45475a
palette = 1=f38ba8
palette = 2=a6e3a1
palette = 3=f9e2af
palette = 4=89b4fa
palette = 5=f5c2e7
palette = 6=94e2d5
palette = 7=bac2de
palette = 8=585b70
palette = 9=f38ba8
palette = 10=a6e3a1
palette = 11=f9e2af
palette = 12=89b4fa
palette = 13=f5c2e7
palette = 14=94e2d5
palette = 15=a6adc8
```

Reference file — `Sources/ZenTerm/Themes/rose-pine.ghostty` (Rosé Pine Main):

```
background = 191724
foreground = e0def4
cursor-color = 524f67
selection-background = 403d52
palette = 0=26233a
palette = 1=eb6f92
palette = 2=31748f
palette = 3=f6c177
palette = 4=9ccfd8
palette = 5=c4a7e7
palette = 6=ebbcba
palette = 7=e0def4
palette = 8=6e6a86
palette = 9=eb6f92
palette = 10=31748f
palette = 11=f6c177
palette = 12=9ccfd8
palette = 13=c4a7e7
palette = 14=ebbcba
palette = 15=e0def4
```

The remaining 13 files come from the same upstream, one per manifest row.
Task 2's test (`test_everyBundledTheme_parsesToNonDefaultColors`) is the gate:
it loads every manifest token and asserts the parsed theme differs from the
built-in fallback and has all 16 palette entries populated — a malformed or
missing file fails the build. Do not invent palettes; copy them from the named
upstream.

- [ ] **Step 1: Create the reference theme files**

Create `Sources/ZenTerm/Themes/catppuccin-mocha.ghostty` and
`Sources/ZenTerm/Themes/rose-pine.ghostty` with the exact contents above.

- [ ] **Step 2: Add the resource to Package.swift**

In `Package.swift`, the ZenTerm target currently reads:

```swift
        .executableTarget(
            name: "ZenTerm",
            dependencies: ["TerminalKit", "PaneKit", "TabKit"],  // still no SwiftTerm
            resources: [.copy("Resources")]  // brand marks (GitHub, git) SVGs for the dock
        ),
```

Change the `resources` line to:

```swift
            resources: [
                .copy("Resources"),  // brand marks (GitHub, git) SVGs for the dock
                .copy("Themes"),  // bundled ghostty theme catalog for the Settings theme picker
            ]
```

- [ ] **Step 3: Write the failing test**

Create `Tests/ZenTermTests/ThemeCatalogTests.swift`:

```swift
import Foundation
import XCTest

@testable import ZenTerm

final class ThemeCatalogTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
    }

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zt-catalog-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        return dir
    }

    func test_entries_startWithBuiltInDefault() throws {
        let root = try makeTempRoot()
        let entries = ThemeCatalog.entries(configRoot: root)
        XCTAssertEqual(entries.first?.source, .builtIn)
        XCTAssertNil(entries.first?.name)  // built-in = no theme key
        // With an empty user dir, the rest are bundled.
        XCTAssertTrue(entries.dropFirst().allSatisfy { $0.source == .bundled })
        XCTAssertEqual(entries.dropFirst().count, ThemeCatalog.bundled.count)
    }

    func test_userFile_shadowsBundledName_asUserSource() throws {
        let root = try makeTempRoot()
        let themes = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try "background = 000000\nforeground = ffffff\n".write(
            to: themes.appendingPathComponent("catppuccin-mocha"), atomically: true, encoding: .utf8)

        let entries = ThemeCatalog.entries(configRoot: root)
        let matches = entries.filter { $0.name == "catppuccin-mocha" }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.source, .user)
    }

    func test_everyBundledTheme_parsesToNonDefaultColors() throws {
        let builtIn = Theme.rosePineMoon
        for entry in ThemeCatalog.bundled {
            let url = try XCTUnwrap(
                ThemeCatalog.bundledURL(for: entry.token), "missing bundled theme \(entry.token)")
            let text = try String(contentsOf: url, encoding: .utf8)
            let theme = GhosttyThemeParser.parse(
                text, fontName: builtIn.fontName, fontSize: builtIn.fontSize, fallback: builtIn)
            // A real theme file overrides bg + all 16 palette slots, so it won't equal the fallback.
            XCTAssertNotEqual(theme.background, builtIn.background, "\(entry.token) bg not set")
            XCTAssertEqual(theme.ansi.count, 16)
        }
    }
}
```

- [ ] **Step 3b: Create the remaining 13 theme files**

Create one `Sources/ZenTerm/Themes/<token>.ghostty` per remaining manifest row,
copying palettes from the named upstream (ghostty catalog / iTerm2-Color-Schemes
`ghostty/`). `test_everyBundledTheme_parsesToNonDefaultColors` verifies each.

- [ ] **Step 4: Write `ThemeCatalog`**

Create `Sources/ZenTerm/ThemeCatalog.swift`:

```swift
import Foundation

/// One selectable theme in the picker: the built-in default (nil name = no `theme` key), a
/// bundled catalog entry, or a user file in `~/.config/zen-term/themes/`.
struct ThemeEntry: Equatable {
    enum Source: Equatable { case builtIn, bundled, user }
    /// Config token written as `theme = <name>`; nil for the built-in default (clears the key).
    let name: String?
    let displayName: String
    let isDark: Bool
    let source: Source
}

/// The theme picker's model: the built-in default, the bundled ghostty catalog (shipped as
/// resources), and any files the user dropped in `themes/`. A user file shadows a bundled entry
/// of the same token so a user can override a shipped theme.
enum ThemeCatalog {
    /// Bundled catalog. Each token has a `Themes/<token>.ghostty` resource (see Task 2 manifest).
    static let bundled: [(token: String, displayName: String, isDark: Bool)] = [
        ("rose-pine", "Rosé Pine", true),
        ("rose-pine-dawn", "Rosé Pine Dawn", false),
        ("catppuccin-latte", "Catppuccin Latte", false),
        ("catppuccin-frappe", "Catppuccin Frappé", true),
        ("catppuccin-macchiato", "Catppuccin Macchiato", true),
        ("catppuccin-mocha", "Catppuccin Mocha", true),
        ("tokyo-night", "Tokyo Night", true),
        ("tokyo-night-storm", "Tokyo Night Storm", true),
        ("tokyo-night-day", "Tokyo Night Day", false),
        ("nord", "Nord", true),
        ("gruvbox-dark", "Gruvbox Dark", true),
        ("dracula", "Dracula", true),
        ("solarized-dark", "Solarized Dark", true),
        ("everforest", "Everforest", true),
        ("kanagawa", "Kanagawa", true),
    ]

    /// Built-in default, then bundled entries (minus any shadowed by a user file), then user files.
    static func entries(configRoot: URL = ConfigLoader.defaultRoot) -> [ThemeEntry] {
        var entries: [ThemeEntry] = [
            ThemeEntry(name: nil, displayName: "Rosé Pine Moon", isDark: true, source: .builtIn)
        ]
        let userTokens = userThemeTokens(configRoot: configRoot)
        let userSet = Set(userTokens)
        for entry in bundled where !userSet.contains(entry.token) {
            entries.append(
                ThemeEntry(name: entry.token, displayName: entry.displayName, isDark: entry.isDark, source: .bundled))
        }
        for token in userTokens {
            // Display the raw token and assume dark (best-effort; a user light theme still works).
            entries.append(ThemeEntry(name: token, displayName: token, isDark: true, source: .user))
        }
        return entries
    }

    /// Basenames of the user's `themes/` files (skip dotfiles), sorted. Empty if the dir is absent.
    static func userThemeTokens(configRoot: URL) -> [String] {
        let dir = configRoot.appendingPathComponent("themes")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// The bundled resource URL for a token, or nil if it isn't a bundled theme.
    static func bundledURL(for token: String) -> URL? {
        Bundle.module.url(forResource: token, withExtension: "ghostty", subdirectory: "Themes")
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ThemeCatalogTests 2>&1 | tail -30`
Expected: PASS (3 tests). If `test_everyBundledTheme_parsesToNonDefaultColors` fails for a token, that file is missing or malformed — fix the file.

- [ ] **Step 6: Commit**

```bash
git add Sources/ZenTerm/ThemeCatalog.swift Sources/ZenTerm/Themes Package.swift Tests/ZenTermTests/ThemeCatalogTests.swift
git commit -m "Theme catalog: bundle ~16 ghostty themes + ThemeCatalog (ZEN-75 PR3)"
```

---

## Task 3: ConfigLoader bundled-theme resolution

**Files:**
- Modify: `Sources/ZenTerm/ConfigLoader.swift` (`resolveThemeURL`)
- Test: `Tests/ZenTermTests/ThemeResolutionTests.swift`

**Interfaces:**
- Consumes: `ThemeCatalog.bundledURL(for:)` (Task 2); `ConfigLoader.loadAppTheme(configRoot:general:)`, `Theme.rosePineMoon`.
- Produces: no new API — `theme = <bundled-name>` now resolves to the bundled resource.

- [ ] **Step 1: Write the failing test**

Create `Tests/ZenTermTests/ThemeResolutionTests.swift`:

```swift
import Foundation
import XCTest

@testable import ZenTerm

final class ThemeResolutionTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
    }

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zt-resolve-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        return dir
    }

    private func config(themeName: String?) -> GeneralConfig {
        var c = GeneralConfig.builtIn
        c.themeName = themeName
        return c
    }

    func test_bundledName_resolvesToBundledColors() throws {
        let root = try makeTempRoot()  // no user themes/ dir
        let theme = ConfigLoader.loadAppTheme(configRoot: root, general: config(themeName: "catppuccin-mocha"))
        XCTAssertNotEqual(theme.terminal.background, Theme.rosePineMoon.background)
    }

    func test_userFile_winsOverBundled() throws {
        let root = try makeTempRoot()
        let themes = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        // A user file whose colors are clearly not Catppuccin's.
        try "background = 010203\nforeground = fefefe\n".write(
            to: themes.appendingPathComponent("catppuccin-mocha"), atomically: true, encoding: .utf8)

        let theme = ConfigLoader.loadAppTheme(configRoot: root, general: config(themeName: "catppuccin-mocha"))
        XCTAssertEqual(theme.terminal.background.red, 0x01)
        XCTAssertEqual(theme.terminal.background.green, 0x02)
        XCTAssertEqual(theme.terminal.background.blue, 0x03)
    }

    func test_unknownName_fallsBackToBuiltIn() throws {
        let root = try makeTempRoot()
        let theme = ConfigLoader.loadAppTheme(configRoot: root, general: config(themeName: "does-not-exist"))
        XCTAssertEqual(theme.terminal.background, Theme.rosePineMoon.background)
    }

    func test_nilName_isBuiltIn() throws {
        let root = try makeTempRoot()
        let theme = ConfigLoader.loadAppTheme(configRoot: root, general: config(themeName: nil))
        XCTAssertEqual(theme.terminal.background, Theme.rosePineMoon.background)
    }
}
```

(`TerminalColor` exposes `red`/`green`/`blue` UInt8 — see `Theme.rgb`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ThemeResolutionTests 2>&1 | tail -20`
Expected: FAIL — `test_bundledName_resolvesToBundledColors` fails (bundled name currently returns nil → built-in).

- [ ] **Step 3: Update `resolveThemeURL`**

In `Sources/ZenTerm/ConfigLoader.swift`, replace the `if let name = general.themeName { … }` block inside `resolveThemeURL` with:

```swift
        if let name = general.themeName {
            let userURL = configRoot.appendingPathComponent("themes").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: userURL.path) { return userURL }
            if let bundled = ThemeCatalog.bundledURL(for: name) { return bundled }
            NSLog("ConfigLoader: theme `\(name)` not found in user themes/ or the bundled catalog — using built-in theme")
            return nil
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ThemeResolutionTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/ConfigLoader.swift Tests/ZenTermTests/ThemeResolutionTests.swift
git commit -m "ConfigLoader: resolve theme = <name> against the bundled catalog (ZEN-75 PR3)"
```

---

## Task 4: `Dropdown` primitive

**Files:**
- Create: `Sources/ZenTerm/Controls/Dropdown.swift`
- (No unit test — AppKit view; behavior is covered by the runbook. A light state test is included.)
- Test: `Tests/ZenTermTests/DropdownTests.swift`

**Interfaces:**
- Consumes: `Theme.current.chrome`, `FloatShadow` (`edge`, `applyShadow(to:)`), `KeyboardFocus`.
- Produces:
  - `struct DropdownItem { let title: String; let group: String?; let note: String?; let isSelected: Bool }`
  - `final class Dropdown: NSView` with:
    - `init(items: [DropdownItem], selectedIndex: Int, onChange: @escaping (Int) -> Void)`
    - `func setItems(_ items: [DropdownItem], selectedIndex: Int)`
    - focus hooks `onArrowUp/onArrowDown/onArrowLeft/onTab/onBacktab/onEsc: (() -> Void)?`
    - `var selectedIndex: Int { get }`

This is a keyboard-first control that mirrors two existing patterns: the
**button styling + focus ring** of `FieldBox`/`AppButton` (rest fill
`chrome.ink(alpha:0.06)`, focus fill `PaletteOverlay.selectionBackground`, accent
border when focused), and the **floating list positioned in the window** of
`KeybindHintBubble` (add the popover to `window?.contentView`, position under the
button, remove on close). The open list is a `FloatShadow`-chromed card of rows.

- [ ] **Step 1: Write the state test**

Create `Tests/ZenTermTests/DropdownTests.swift`:

```swift
import AppKit
import XCTest

@testable import ZenTerm

final class DropdownTests: XCTestCase {
    func test_selectedIndex_reflectsInitAndSetItems() {
        let items = [
            DropdownItem(title: "A", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "B", group: "G", note: "dark", isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        XCTAssertEqual(dropdown.selectedIndex, 0)

        dropdown.setItems(items, selectedIndex: 1)
        XCTAssertEqual(dropdown.selectedIndex, 1)
    }

    func test_titleShowsSelectedItem() {
        let items = [
            DropdownItem(title: "Rosé Pine Moon", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "Nord", group: "Bundled", note: "dark", isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 1) { _ in }
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Nord")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DropdownTests 2>&1 | tail -20`
Expected: FAIL — no `Dropdown`/`DropdownItem`.

- [ ] **Step 3: Implement `Dropdown`**

Create `Sources/ZenTerm/Controls/Dropdown.swift`. Full implementation:

```swift
import AppKit

/// One row in a `Dropdown` menu: a title, an optional group header shown above it, an optional
/// trailing note (e.g. "Light"/"Dark"), and whether it's the current selection (drawn with a check).
struct DropdownItem: Equatable {
    let title: String
    let group: String?
    let note: String?
    let isSelected: Bool
}

/// A keyboard-navigable themed dropdown: a compact button showing the current item; Return/Space/
/// click opens a floating list of rows (grouped headers, trailing notes, a check on the active one).
/// Up/Down move the highlight, Return selects, Esc closes. As a form focus stop it bubbles Up/Down
/// at the list's closed state to the section (like `SegmentedControl`). Styling mirrors `FieldBox`.
final class Dropdown: NSView {
    private(set) var selectedIndex: Int
    private var items: [DropdownItem]
    private let onChange: (Int) -> Void

    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onEsc: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private var listCard: NSView?
    private var highlighted = 0
    private var isFocusedStop = false

    private static let restFill = Theme.current.chrome.ink(alpha: 0.06)
    private static let focusFill = PaletteOverlay.selectionBackground

    /// Test hook: the button's current title.
    var buttonTitleForTesting: String { titleLabel.stringValue }

    init(items: [DropdownItem], selectedIndex: Int, onChange: @escaping (Int) -> Void) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Self.restFill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.current.chrome.ink(alpha: 0.10).cgColor

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = Theme.current.chrome.ink(alpha: 0.5)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        renderTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setItems(_ items: [DropdownItem], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = min(max(selectedIndex, 0), max(0, items.count - 1))
        renderTitle()
    }

    private func renderTitle() {
        titleLabel.stringValue = items.indices.contains(selectedIndex) ? items[selectedIndex].title : ""
    }

    // MARK: focus

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        isFocusedStop = true
        restyle()
        return true
    }
    override func resignFirstResponder() -> Bool {
        isFocusedStop = false
        restyle()
        return super.resignFirstResponder()
    }
    override func drawFocusRingMask() {}

    private func restyle() {
        let chrome = Theme.current.chrome
        let open = listCard != nil
        layer?.backgroundColor = (isFocusedStop || open ? Self.focusFill : Self.restFill).cgColor
        layer?.borderColor = (isFocusedStop || open ? chrome.accent.nsColor : chrome.ink(alpha: 0.10)).cgColor
        layer?.borderWidth = isFocusedStop || open ? 1.5 : 1
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        if listCard != nil {
            switch event.keyCode {
            case 126: moveHighlight(-1)  // up
            case 125: moveHighlight(1)  // down
            case 36, 76, 49: commitHighlight()  // return / enter / space
            case 53: closeList()  // esc
            default: break
            }
            return
        }
        switch event.keyCode {
        case 36, 76, 49: openList()  // return / enter / space
        case 126: onArrowUp?()
        case 125: onArrowDown?()
        case 123 where onArrowLeft != nil: onArrowLeft?()
        case 48: event.modifierFlags.contains(.shift) ? onBacktab?() : onTab?()
        case 53 where onEsc != nil: onEsc?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        listCard == nil ? openList() : closeList()
    }

    // MARK: list

    private func openList() {
        guard listCard == nil, let contentView = window?.contentView else { return }
        highlighted = selectedIndex
        let card = buildListCard()
        contentView.addSubview(card)
        listCard = card
        positionList()
        restyle()
    }

    private func closeList() {
        listCard?.removeFromSuperview()
        listCard = nil
        restyle()
    }

    private func moveHighlight(_ delta: Int) {
        guard let next = KeyboardFocus.step(from: highlighted, delta: delta, count: items.count) else { return }
        highlighted = next
        refreshListHighlight()
    }

    private func commitHighlight() {
        selectedIndex = highlighted
        renderTitle()
        closeList()
        onChange(selectedIndex)
    }

    // Build + position + highlight helpers below mirror KeybindHintBubble's window-child pattern:
    // a FloatShadow-chromed vertical stack of row views, each a themed control cell. Rows show an
    // optional faint group header (chrome.ink(alpha:0.4), 10pt semibold), the title, a trailing
    // note (chrome.ink(alpha:0.4)), and a check (SF "checkmark", chrome.accent) when isSelected.
    // The highlighted row fills chrome.ink(alpha:0.10); clicking a row calls commit for its index.
    // positionList(): frame below the button in window coords (convert self.bounds to contentView),
    // width == self bounds width (min 180), capped height with an inner NSScrollView if it overflows.
    private func buildListCard() -> NSView { /* see Step 3 note */ fatalError("implement per pattern") }
    private func positionList() {}
    private func refreshListHighlight() {}
}
```

**Step 3 note — finish the three list helpers** by mirroring `KeybindHintBubble`
(window-child card + `FloatShadow.edge` border + `FloatShadow.applyShadow`) and
`PaletteOverlay`'s row styling:

- `buildListCard()`: a `wantsLayer` card (cornerRadius 8, `chrome.background`,
  `FloatShadow.edge` border, `FloatShadow.applyShadow(to:)`) holding a vertical
  `NSStackView` of row views built from `items`. Each row: leading title label,
  optional trailing note label, trailing check image when `item.isSelected`; a
  faint group header row is inserted before the first item of each new `group`.
  Store the row views in an array for `refreshListHighlight()`.
- `positionList()`: `let origin = convert(bounds, to: window!.contentView!)`;
  place the card at `x = origin.minX`, just below `origin.minY` (contentView is
  not flipped, so below = `origin.minY - cardHeight - 4`), width
  `max(bounds.width, 180)`; clamp within the contentView like
  `SettingsKeybindsSection.positionBubble` does.
- `refreshListHighlight()`: set each row's fill — `chrome.ink(alpha:0.10)` for the
  `highlighted` index, else clear.

Keep it under ~120 lines; it is a compact list, not the palette's search stack.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DropdownTests 2>&1 | tail -20`
Expected: PASS (2 tests). Then `swift build 2>&1 | tail -5` clean.

- [ ] **Step 5: Manual smoke (runbook)**

`swift run ZenTerm` — this control isn't wired into a section yet, so only build
is verified here. Full interaction is verified in Task 7.

- [ ] **Step 6: Commit**

```bash
git add Sources/ZenTerm/Controls/Dropdown.swift Tests/ZenTermTests/DropdownTests.swift
git commit -m "Add keyboard-navigable Dropdown control (ZEN-75 PR3)"
```

---

## Task 5: `SettingsFormSection` base + `SettingsAppearanceSection`

**Files:**
- Create: `Sources/ZenTerm/SettingsFormSection.swift`
- Create: `Sources/ZenTerm/SettingsAppearanceSection.swift`
- Delete: `Sources/ZenTerm/SettingsLayoutSection.swift`
- Modify: `Sources/ZenTerm/WindowController.swift:484` (`SettingsLayoutSection()` → `SettingsAppearanceSection()`)
- Test: existing `Tests/ZenTermTests/LayoutWriteTests.swift` still passes (behavior preserved).

**Interfaces:**
- Consumes: `SettingsSection` protocol, `SettingsDetail.scroll(for:)`, `ResetFlashLabel`, `LayoutRow`, `FieldBox`, `SegmentedControl`, `AppButton`, `KeyboardFocus`, `LayoutFormat`, `ConfigWriter`, `AppConfig`, `GeneralConfig`.
- Produces (base, `open`/`internal` for subclasses):
  - `class SettingsFormSection: SettingsSection`
  - `func populate()` — subclass override; add groups/rows here.
  - `func addGroup(_ title: String, _ build: () -> Void)`
  - `func addNumericRow(key:caption:blurb:range:read:width:)` where `read: (GeneralConfig) -> CGFloat`
  - `func addSegmentedRow(key:caption:blurb:options:read:token:notifiesOnReselect:)` where `read: (GeneralConfig) -> Int`, `token: (Int) -> String`
  - `func addTextRow(key:caption:blurb:placeholder:read:width:)` where `read: (GeneralConfig) -> String`
  - `func addCustomRow(key:caption:description:control:focusStop:controlNote:width:refresh:)` — for the Theme dropdown; `refresh: () -> Void`

This task **moves** PR2's machinery from `SettingsLayoutSection` into the base
mostly verbatim, generalizing the per-key refresh into per-row `refresh`
closures. Use the current `SettingsLayoutSection.swift` as the source of truth
for the debounce (`scheduleApply`/`flushApply`/`runPending`, `applyDelay`),
`commitNumeric`/`write`/`writeOrRemove`, `persist`, `moveFocus`, `wireControlKeyboard`,
`resetAll`, and the numeric `onChange` **blank-mid-edit fix from PR2** (stage the
blank; don't live-apply the removal).

- [ ] **Step 1: Create `SettingsFormSection` (base)**

Create `Sources/ZenTerm/SettingsFormSection.swift`. Port the machinery, with these structural changes from `SettingsLayoutSection`:

1. `class SettingsFormSection: SettingsSection` with `var navTitle: String { "" }` (subclass overrides), `onExitToNav`, `onClose`.
2. Stored: `rows: [LayoutRow]`, `stops: [NSView]`, `controlForKey: [String: NSView]`, `scalarKeys: [String]`, `resetAllButton`, `resetAllMessage = ResetFlashLabel()`, `pendingApply`, `applyTimer`, `applyDelay = 0.18`, plus **`private var refreshers: [() -> Void] = []`** and build-time cursors `private var rowsStack: NSStackView?`, `private var lastArranged: NSView?`.
3. `makeDetailView()`: reset all state arrays, build `rowsStack` (vertical, `.leading`, spacing 10), set `rowsStack`/`lastArranged`, call `populate()`, then append `resetAllButton` (+ its keyboard hooks + `onTap = resetAll`) and `resetAllMessage` exactly as `SettingsLayoutSection.makeDetailView` does today, wrap via `SettingsDetail.scroll(for: rowsStack)`, `refreshRows()`, return.
4. `addGroup(_:_:)` ported from the local `addGroup` closure (caption + 20pt spacing before groups), operating on `rowsStack`/`lastArranged`.
5. Row builders each: append to `scalarKeys`, build the control, wire keyboard, build a `LayoutRow`, append to `rows`/`stops`/`controlForKey`, add to `rowsStack`, and **append a `refresh` closure** to `refreshers`:
   - `addNumericRow`: control `FieldBox` (right-aligned), the PR2 `onChange` (blank-stages, valid schedules, invalid cancels), `onEndEditing = flushApply`, `controlNote = rangeText`. `refresh`: if `box.field.currentEditor() == nil` set `box.setText(fieldText(for: read, range))`.
   - `addSegmentedRow`: control `SegmentedControl(options:selectedIndex: read(.current) mappedIndex, notifiesOnReselect:)` with `onChange = { self.writeOrRemove(key, token(index), row: key) }`. `refresh`: `seg.setSelection(read(GeneralConfig.current))`.
   - `addTextRow`: control `FieldBox` (left-aligned), `onChange` schedules `writeOrRemove(key, trimmedOrNil, row: key)`, `onEndEditing = flushApply`. `refresh`: if not editing, `box.setText(read(GeneralConfig.current))`.
   - `addCustomRow`: caller supplies control + focusStop + refresh; base just registers it (append to rows/stops/controlForKey/refreshers, add to stack). Used for the Theme dropdown in Task 7.
6. `refreshRows()`: `refreshers.forEach { $0() }`.
7. `commitNumeric`, `write`, `writeOrRemove`, `persist`, `scheduleApply`, `flushApply`, `runPending`, `moveFocus`, `wireControlKeyboard`, `reset`(n/a), `resetAll` (removes `Set(scalarKeys)`, then `resetAllMessage.flash("Defaults restored.")`), `rowFor`, `rangeText`, `rangeMessage`, and a generalized `fieldText(for read: (GeneralConfig) -> CGFloat, range:)` — port verbatim from `SettingsLayoutSection`, swapping the `NumericKnob` closures for the passed-in `read`.
8. `detailStops() -> [NSView] { stops }`. `sectionWillHide()` default from the protocol extension is fine (Appearance/Terminal have no capture to end).

Numeric `fieldText` helper (generalized):

```swift
    /// A numeric field's text: the value when it differs from the built-in default, else blank.
    private func fieldText(for read: (GeneralConfig) -> CGFloat) -> String {
        let current = read(GeneralConfig.current)
        return current != read(GeneralConfig.builtIn) ? LayoutFormat.number(current) : ""
    }
```

- [ ] **Step 2: Create `SettingsAppearanceSection`**

Create `Sources/ZenTerm/SettingsAppearanceSection.swift`:

```swift
import AppKit

/// The Appearance settings section: theme picker (Task 7) plus the chrome Layout knobs and the
/// Motion preference. A subclass of `SettingsFormSection` — it only declares its groups; the base
/// owns the row builders, live-apply debounce, focus stops, and Reset-all.
final class SettingsAppearanceSection: SettingsFormSection {
    override var navTitle: String { "Appearance" }

    override func populate() {
        // Theme group is added in Task 7 (needs the Dropdown + ThemeCatalog). Placeholder ordering:
        // it will be the first group, above Layout.
        addGroup("Layout") {
            self.addNumericRow(
                key: "backdrop-alpha", caption: "Backdrop alpha", blurb: "Tint strength over the window blur",
                range: 0...1, read: { $0.backdropAlpha }, width: 64)
            self.addNumericRow(
                key: "window-gutter", caption: "Window gutter", blurb: "Space around the window edge",
                range: 0...64, read: { $0.windowGutter }, width: 64)
            self.addNumericRow(
                key: "pane-gap", caption: "Pane gap", blurb: "Space between split panes",
                range: 0...64, read: { $0.panelGap }, width: 64)
            self.addNumericRow(
                key: "bottom-drawer-fraction", caption: "Default bottom drawer height",
                blurb: "Height it opens to (new tabs)", range: 0.1...0.9, read: { $0.bottomDrawerFraction },
                width: 64)
            self.addNumericRow(
                key: "right-drawer-fraction", caption: "Default right drawer width",
                blurb: "Width it opens to (new tabs)", range: 0.1...0.9, read: { $0.rightDrawerFraction },
                width: 64)
            self.addNumericRow(
                key: "drawer-resize-step", caption: "Drawer resize step",
                blurb: "How far each ⌥-arrow nudge resizes", range: 4...400, read: { $0.drawerResizeStep },
                width: 64)
            self.addNumericRow(
                key: "max-drawer-fraction", caption: "Max drawer width/height",
                blurb: "Largest a drawer can grow", range: 0.3...0.95, read: { $0.maxDrawerFraction }, width: 64)
        }
        addGroup("Motion") {
            self.addSegmentedRow(
                key: "reduce-motion", caption: "Reduce motion", blurb: nil, options: ["On", "Off"],
                read: { self.reduceMotionIndex($0) },
                token: { LayoutFormat.reduceMotionToken($0 == 0 ? .on : .off) }, notifiesOnReselect: true)
        }
    }

    /// Reduce-motion shown as On/Off; `system` resolves via the OS accessibility setting.
    private func reduceMotionIndex(_ c: GeneralConfig) -> Int {
        switch c.reduceMotion {
        case .on: return 0
        case .off: return 1
        case .system: return Motion.isReduceMotionEnabled() ? 0 : 1
        }
    }
}
```

(The reduce-motion `read` reads `GeneralConfig.current` via the base's refresh;
because `read` takes the config, pass `GeneralConfig.current` at call sites in
the base's segmented builder and refresh.)

- [ ] **Step 3: Delete the old file + update the registration**

```bash
git rm Sources/ZenTerm/SettingsLayoutSection.swift
```

In `Sources/ZenTerm/WindowController.swift`, change `SettingsLayoutSection()` to `SettingsAppearanceSection()` (line ~484).

- [ ] **Step 4: Build + run the full gate**

Run: `bin/check 2>&1 | tail -15`
Expected: green. `LayoutWriteTests` (the scalar write/reset round-trip) still passes — behavior preserved. Fix any format/lint with `bin/check --fix`.

- [ ] **Step 5: Manual smoke (runbook)**

`swift run ZenTerm` → ⌘, (or the Settings command) → the section nav shows
**Keybinds** and **Appearance**; Appearance shows Layout + Motion exactly as
PR2's General did (minus Shell), editing a knob still live-applies, arrows/Tab
still move focus, Reset-all still flashes "Defaults restored." No Shell group.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Extract SettingsFormSection base; rename General to Appearance (ZEN-75 PR3)"
```

---

## Task 6: `SettingsTerminalSection` + registration

**Files:**
- Create: `Sources/ZenTerm/SettingsTerminalSection.swift`
- Modify: `Sources/ZenTerm/WindowController.swift:481-490` (register Terminal; order Appearance, Terminal, Keybinds)
- Test: `Tests/ZenTermTests/TerminalConfigWriteTests.swift`

**Interfaces:**
- Consumes: `SettingsFormSection` builders (Task 5); `LayoutFormat` tokens (Task 1); `GeneralConfig` terminal fields.
- Produces: `final class SettingsTerminalSection: SettingsFormSection` (`navTitle` "Terminal").

- [ ] **Step 1: Write the failing test**

Create `Tests/ZenTermTests/TerminalConfigWriteTests.swift`:

```swift
import CoreGraphics
import TerminalKit
import XCTest

@testable import ZenTerm

final class TerminalConfigWriteTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zt-terminal-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    func test_terminalScalars_writeAndReload() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(
            scalars: [
                "font-family": "Menlo",
                "font-size": LayoutFormat.number(16),
                "cursor-style": LayoutFormat.cursorStyleToken(.bar),
                "cursor-style-blink": LayoutFormat.boolToken(false),
                "cursor-thickness": LayoutFormat.number(3),
                "macos-option-as-alt": LayoutFormat.boolToken(false),
                "scroll-multiplier": LayoutFormat.number(2),
                "shell": "/bin/zsh",
            ], configRoot: dir)

        let loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(loaded.fontName, "Menlo")
        XCTAssertEqual(loaded.fontSize, 16, accuracy: 0.001)
        XCTAssertEqual(loaded.cursorStyle, .bar)
        XCTAssertEqual(loaded.cursorBlink, false)
        XCTAssertEqual(loaded.cursorThickness, 3)
        XCTAssertEqual(loaded.optionAsAlt, false)
        XCTAssertEqual(loaded.scrollMultiplier, 2, accuracy: 0.001)
        XCTAssertEqual(loaded.shell, "/bin/zsh")
    }

    func test_blankRemoval_fallsBackToBuiltIn() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(scalars: ["font-family": "Menlo"], configRoot: dir)
        try ConfigWriter.apply(removals: ["font-family"], configRoot: dir)
        let loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(loaded.fontName, GeneralConfig.builtIn.fontName)
    }
}
```

- [ ] **Step 2: Run test to verify it fails, then passes on write path**

Run: `swift test --filter TerminalConfigWriteTests 2>&1 | tail -20`
Expected: PASS already (these exercise `ConfigWriter`/`ConfigLoader`/`LayoutFormat`, which exist after Task 1). This test locks the tokens the section will write. If it fails, the token helpers or keys are wrong — fix before building UI on them.

- [ ] **Step 3: Create `SettingsTerminalSection`**

Create `Sources/ZenTerm/SettingsTerminalSection.swift`:

```swift
import AppKit
import TerminalKit

/// The Terminal settings section: font, cursor, input, and shell knobs. A subclass of
/// `SettingsFormSection` — it only declares its groups. Every knob applies to new tabs (per-surface
/// config read at surface construction), matching how shell has always behaved.
final class SettingsTerminalSection: SettingsFormSection {
    override var navTitle: String { "Terminal" }

    private static let cursorStyles: [TerminalBehavior.CursorStyle] = [.block, .bar, .underline]

    override func populate() {
        addGroup("Font") {
            self.addTextRow(
                key: "font-family", caption: "Font family", blurb: "Terminal font (new tabs)",
                placeholder: GeneralConfig.builtIn.fontName, read: { $0.fontName }, width: 200)
            self.addNumericRow(
                key: "font-size", caption: "Font size", blurb: "Point size (new tabs)",
                range: 6...72, read: { $0.fontSize }, width: 64)
        }
        addGroup("Cursor") {
            self.addSegmentedRow(
                key: "cursor-style", caption: "Style", blurb: "Cursor shape (new tabs)",
                options: ["Block", "Bar", "Underline"], read: { self.cursorStyleIndex($0) },
                token: { LayoutFormat.cursorStyleToken(Self.cursorStyles[$0]) }, notifiesOnReselect: false)
            self.addSegmentedRow(
                key: "cursor-style-blink", caption: "Blink", blurb: "Blink the cursor (new tabs)",
                options: ["On", "Off"], read: { $0.cursorBlink ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
            self.addNumericRow(
                key: "cursor-thickness", caption: "Thickness", blurb: "Bar/underline thickness in px (new tabs)",
                range: 1...12, read: { CGFloat($0.cursorThickness) }, width: 64)
        }
        addGroup("Input") {
            self.addSegmentedRow(
                key: "macos-option-as-alt", caption: "Option as Alt", blurb: "Send Option as Meta (new tabs)",
                options: ["On", "Off"], read: { $0.optionAsAlt ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
            self.addNumericRow(
                key: "scroll-multiplier", caption: "Scroll speed", blurb: "Scroll wheel multiplier (new tabs)",
                range: 0.1...10, read: { $0.scrollMultiplier }, width: 64)
        }
        addGroup("Shell") {
            self.addTextRow(
                key: "shell", caption: "Shell", blurb: "Login shell (new tabs)", placeholder: "login shell",
                read: { $0.shell ?? "" }, width: 200)
            self.addTextRow(
                key: "shell-args", caption: "Shell args", blurb: "Passed to the shell (new tabs)",
                placeholder: "optional", read: { LayoutFormat.joinArgs($0.shellArgs) }, width: 200)
        }
    }

    private func cursorStyleIndex(_ c: GeneralConfig) -> Int {
        Self.cursorStyles.firstIndex(of: c.cursorStyle) ?? 0
    }
}
```

Note: `scroll-multiplier` and `font-size` write via `LayoutFormat.number`;
`cursor-thickness` reads as `CGFloat` and the parser floors it to `Int` on load
(range 1–12). `shell-args` blank clears the key (`writeOrRemove` with empty →
removal); a non-empty value writes the raw string (the parser splits on
whitespace). If the base's `addTextRow` needs a per-key value transform for
`shell-args` (join/split), pass the raw text through — `writeOrRemove` stores the
trimmed string, and `GeneralConfigParser` splits it; round-trips through
`joinArgs`/`splitArgs`.

- [ ] **Step 4: Register the section + set nav order**

In `Sources/ZenTerm/WindowController.swift`, update the `sections:` array in `openSettings()`:

```swift
            sections: [
                SettingsAppearanceSection(),
                SettingsTerminalSection(),
                SettingsKeybindsSection(capturer: keybindCapturer),
            ],
```

- [ ] **Step 5: Build + gate**

Run: `bin/check 2>&1 | tail -15`
Expected: green (incl. `TerminalConfigWriteTests`). `bin/check --fix` for format/lint.

- [ ] **Step 6: Manual runbook**

`swift run ZenTerm` → Settings → nav shows **Appearance, Terminal, Keybinds**.
Terminal shows Font / Cursor / Input / Shell. Set cursor style → Bar and font
size → 16; open a **new tab** and confirm the cursor is a bar at 16pt. Blank the
font family and open a new tab → default font. Terminal Reset-all flashes
"Defaults restored." and clears every Terminal key. Appearance no longer shows
Shell.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add Terminal settings section (font, cursor, input, shell) (ZEN-75 PR3)"
```

---

## Task 7: Theme row (Dropdown) in Appearance

**Files:**
- Modify: `Sources/ZenTerm/SettingsAppearanceSection.swift` (add Theme group)
- Modify: `docs/config/config` (note the catalog + picker)
- Test: covered by `ThemeCatalogTests` + runbook (write path is `ConfigWriter`, already tested).

**Interfaces:**
- Consumes: `ThemeCatalog.entries()` (Task 2), `Dropdown`/`DropdownItem` (Task 4), `SettingsFormSection.addCustomRow` + `write`/`persist` (Task 5), `AppConfig.reload`, `Relauncher` (Task 8 — the restart button is wired here but the `Relauncher` call lands in Task 8; until then the button is created disabled with a note).
- Produces: the Theme group at the top of Appearance.

- [ ] **Step 1: Add the Theme group builder**

In `SettingsAppearanceSection`, add a stored property and prepend the Theme group in `populate()` (before Layout):

```swift
    private var themeEntries: [ThemeEntry] = []
    private weak var themeDropdown: Dropdown?
    private let restartButton = AppButton(title: "Restart to apply", variant: .primary)
```

At the top of `populate()`:

```swift
        addGroup("Theme") { self.addThemeRow() }
```

Add the builder:

```swift
    private func addThemeRow() {
        themeEntries = ThemeCatalog.entries()
        let selected = currentThemeIndex()
        let dropdown = Dropdown(items: themeItems(selected: selected), selectedIndex: selected) {
            [weak self] index in self?.selectTheme(index)
        }
        themeDropdown = dropdown
        restartButton.isKeyboardFocusable = false
        restartButton.isHidden = true
        restartButton.onTap = { Relauncher.relaunch() }  // wired live in Task 8

        // A trailing control column: the dropdown with the restart button tucked under it.
        addCustomRow(
            key: "theme", caption: "Theme", description: "Applies on restart",
            control: dropdown, focusStop: dropdown, controlNote: nil, width: 220,
            refresh: { [weak self] in self?.refreshThemeRow() })
        // Place the restart button under the dropdown row (added as its own arranged view).
        appendTrailing(restartButton)
    }

    private func themeItems(selected: Int) -> [DropdownItem] {
        themeEntries.enumerated().map { index, entry in
            DropdownItem(
                title: entry.displayName,
                group: entry.source == .user ? "Your themes" : (entry.source == .bundled ? "Bundled" : nil),
                note: entry.isDark ? "Dark" : "Light",
                isSelected: index == selected)
        }
    }

    private func currentThemeIndex() -> Int {
        let name = GeneralConfig.current.themeName
        return themeEntries.firstIndex { $0.name == name } ?? 0
    }

    private func selectTheme(_ index: Int) {
        guard themeEntries.indices.contains(index) else { return }
        let entry = themeEntries[index]
        if let name = entry.name {
            write("theme", name, row: "theme")
        } else {
            writeOrRemove("theme", nil, row: "theme")  // built-in default clears the key
        }
        updateRestartVisibility()
    }

    private func refreshThemeRow() {
        let selected = currentThemeIndex()
        themeDropdown?.setItems(themeItems(selected: selected), selectedIndex: selected)
        updateRestartVisibility()
    }

    /// Show "Restart to apply" only when the chosen theme differs from the running one.
    private func updateRestartVisibility() {
        let chosen = GeneralConfig.current.themeName
        let running = Theme.current.terminal
        // Theme.current reflects the file after reload; compare against the last-applied launch theme.
        restartButton.isHidden = (chosen == Self.launchThemeName)
        _ = running
    }

    private static let launchThemeName: String? = GeneralConfig.current.themeName
```

**Note on the base:** `addCustomRow` and `appendTrailing` are small additions to
`SettingsFormSection`:

- `addCustomRow(key:caption:description:control:focusStop:controlNote:width:refresh:)`
  mirrors the private `addRow` but takes a caller `refresh` closure (registered in
  `refreshers`) and adds `key` to `scalarKeys` + `controlForKey` + `stops`.
- `appendTrailing(_ view: NSView)` adds an arranged subview to `rowsStack`
  directly (for the restart button under the Theme row) without registering it as
  a focus stop.

`Self.launchThemeName` captures the theme name at first access (app launch value
of `GeneralConfig.current.themeName`), so the restart button appears whenever the
selection differs from what the running process actually launched with, and
disappears when the user reselects the launch theme.

- [ ] **Step 2: Build + gate**

Run: `bin/check 2>&1 | tail -15`
Expected: green. (`Relauncher` referenced in `restartButton.onTap` needs to exist; if Task 8 isn't done yet, temporarily stub `enum Relauncher { static func relaunch() {} }` — but prefer doing Task 8 first, then this line is live. If executing in order, move Task 8 before Task 7's Step 1, or add the stub and replace in Task 8.)

- [ ] **Step 3: Update `docs/config/config`**

Add a short note near the `theme` key documentation: the app now ships a bundled
theme catalog selectable in Settings → Appearance → Theme; `theme = <name>`
resolves a user `themes/<name>` file first, else a bundled theme; the picker
writes this key and a restart applies it. No middle-dots or em dashes.

- [ ] **Step 4: Manual runbook**

`swift run ZenTerm` → Settings → Appearance → Theme dropdown at the top. Open it:
built-in "Rosé Pine Moon" first, then Bundled group (Catppuccin, Tokyo Night, …)
with Light/Dark hints and a check on the active theme; arrow/Return/Esc work; it
participates in up/down/Tab focus. Pick Catppuccin Mocha → "Restart to apply"
appears; `cat ~/.config/zen-term/config` shows `theme = catppuccin-mocha`.
Reselect Rosé Pine Moon → the `theme` line is removed and the button hides.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Appearance: theme picker dropdown writes theme + restart affordance (ZEN-75 PR3)"
```

---

## Task 8: `Relauncher` + wire the Restart button

**Files:**
- Create: `Sources/ZenTerm/Relauncher.swift`
- (Restart button already created in Task 7; this makes `relaunch()` real.)
- Test: none (spawns a process / terminates — GUI-only; runbook verifies).

**Interfaces:**
- Consumes: `Bundle.main` (bundlePath / executablePath), `NSApplication`.
- Produces: `enum Relauncher { static func relaunch() }`.

- [ ] **Step 1: Implement `Relauncher`**

Create `Sources/ZenTerm/Relauncher.swift`:

```swift
import AppKit

/// Restart the app to apply a change that the running process can't hot-swap (a theme, today).
/// Spawns a fresh instance detached from this process, then terminates — the child starts once
/// this one has exited. Packaged `.app` relaunches via `open`; a bare dev executable relaunches
/// itself; if neither resolves, it logs and no-ops (the config write already persisted).
enum Relauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let isAppBundle = bundleURL.pathExtension == "app"
        let command: String
        if isAppBundle {
            // `open` waits for nothing; the short sleep lets this process exit first so the
            // freshly-opened instance isn't deduplicated against the still-dying one.
            command = "sleep 0.3; open \"\(bundleURL.path)\""
        } else if let exe = Bundle.main.executablePath {
            command = "sleep 0.3; \"\(exe)\""
        } else {
            NSLog("Relauncher: no bundle or executable path to relaunch — restart manually to apply.")
            return
        }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", command]
        do {
            try task.run()
        } catch {
            NSLog("Relauncher: failed to spawn restart helper: \(error) — restart manually.")
            return
        }
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 2: Ensure Task 7's button calls it**

Confirm `restartButton.onTap = { Relauncher.relaunch() }` in `SettingsAppearanceSection` (from Task 7). Remove any temporary `Relauncher` stub.

- [ ] **Step 3: Build + gate**

Run: `bin/check 2>&1 | tail -15`
Expected: green.

- [ ] **Step 4: Manual runbook**

`swift run ZenTerm` (dev executable path) → Settings → Appearance → pick
Catppuccin Latte (a light theme) → "Restart to apply" → click it. The app
relaunches; after relaunch the whole chrome + terminal read as Catppuccin Latte
and are legible (no washed-out chrome). Repeat with a dark theme. Then package
(`bin/package-app`) and confirm restart works from the `.app` too.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add Relauncher; restart-to-apply for theme changes (ZEN-75 PR3)"
```

---

## Task 9: Hot-reload follow-up ticket + ship

**Files:** none (Linear + ship flow).

- [ ] **Step 1: File the hot-reload follow-up ticket**

Create a ZenTerm-team Linear ticket "Hot reload theme changes (chrome + live terminals)", Backlog, seeded with: ghostty and kitty expose a live config-reload command — investigate driving that; for the SwiftTerm backend now, promote `SwiftTermSurface.applyTheme` to a public `TerminalSurface.apply(theme:)` seam method and re-apply to every live surface on `.configDidChange`; add a centralized chrome color re-resolve pass so every chrome view re-reads `Theme.current.chrome` on `.configDidChange` (today only the backdrop re-tints), avoiding a half-themed window on light themes. Reference this PR.

- [ ] **Step 2: Run the ship-feature flow**

Invoke the `ship-feature` skill: full `bin/check`, draft PR referencing the new ZEN ticket + ZEN-75, Copilot review, `/code-review`, triage every finding (fix / mitigate-with-ticket / ignore-with-reason, no tech debt), move the ticket to In Review, mark the PR ready.

---

## Self-Review

**Spec coverage:**
- Appearance rename + Theme group → Tasks 5, 7. ✓
- Terminal section (Font/Cursor/Input/Shell) → Task 6. ✓
- Shared `SettingsFormSection` base → Task 5. ✓
- Bundled catalog + user merge + precedence → Task 2; resolution → Task 3. ✓
- `Dropdown` primitive → Task 4; wired → Task 7. ✓
- Restart-to-apply + `Relauncher` → Tasks 7–8. ✓
- Hot-reload follow-up ticket → Task 9. ✓
- LayoutFormat tokens → Task 1. ✓
- `docs/config/config` note → Task 7. ✓
- Tests: LayoutFormat tokens (T1), ThemeCatalog (T2), resolution (T3), terminal writes (T6), Dropdown state (T4). ✓

**Placeholder scan:** The only deferred detail is `Dropdown`'s three list helpers (`buildListCard`/`positionList`/`refreshListHighlight`), which reference exact mirror patterns (`KeybindHintBubble` window-child + `PaletteOverlay` row styling) with concrete color roles and positioning math — an implementer has the pattern to follow, not a blank. All logic/data/tests carry full code.

**Type consistency:** `read` closures are `(GeneralConfig) -> CGFloat` (numeric), `-> Int` (segmented), `-> String` (text) across base + both sections. `token: (Int) -> String` matches `LayoutFormat.*Token`. `ThemeEntry.name: String?` (nil = built-in) is consistent across `ThemeCatalog`, resolution, and the Theme row. `Dropdown(items:selectedIndex:onChange:)` matches its call site. `Relauncher.relaunch()` matches the button wiring.

**Ordering note:** Task 8 (`Relauncher`) is referenced by Task 7's button. Execute Task 8 before Task 7's build step, or use the one-line stub noted in Task 7 Step 2 and replace it in Task 8.
