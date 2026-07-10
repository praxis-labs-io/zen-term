# Settings card + Keybinds section (ZEN-75 PR1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the foundation of ZEN-75 — a config writer, a save→reload→apply seam, a keyboard-first Settings card, and a Keybinds section that rebinds actions and applies them live with no restart.

**Architecture:** A new `ConfigWriter` edits the flat `~/.config/zen-term/config` file in place (preserving comments/unknown keys), mirroring `WorkspacesWriter`'s safety guards. `GeneralConfig.current` / `Theme.current` flip from launch-only `static let` to `static private(set) var` that `AppConfig.reload()` re-resolves from disk before posting `configDidChange`; the keymap is PR1's one wired consumer. A `SettingsOverlay` (`ModalOverlay`, like the palettes) hosts a left-nav ↔ right-detail split driven by a shared `KeyboardFocus` engine extracted from `AddWorkspaceOverlay`, and registers a single Keybinds section.

**Tech Stack:** Swift 5.9+, SwiftPM, AppKit. No Xcode required. Tests are XCTest via `swift test`.

## Global Constraints

- Build/test/lint gate: `bin/check` must be fully green — `swift build` + `swift test` + `swift format lint --strict` + `swiftlint --strict`. `bin/check --fix` auto-applies formatter/linter fixes.
- The chrome never hardcodes a color. Every color resolves from `Theme.current.chrome` roles (`background`, `foreground`, `info`, `warning`, `destructive`, `accent`, `attention`, `muted`) or `chrome.ink(alpha:)`. Banned: `NSColor(white:…)`, `.white`/`.black`, raw hex, literal palette values.
- `Sources/ZenTerm/` must never `import SwiftTerm` (or any backend). All work here is chrome-only.
- PascalCase types; one primary type per file; filename matches the primary type. Booleans prefixed `is`/`has`/`should`/`can`. Functions verb-first. Constants `SCREAMING_SNAKE` (Swift: `static let` camelCase is the repo norm).
- No force-unwrap except documented AppKit (`contentView!`). No `TODO`/`FIXME`/`HACK`/`XXX`/`TEMP` markers. No `swiftlint:disable`. Prefer `type` aliases / `struct` / `final class`; `import type` N/A (Swift).
- Commit message trailer (every commit): `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Reuse the ZEN-81 control primitives in `Sources/ZenTerm/Controls/` (`AppButton`, `SegmentedControl`, `FieldBox`, `LabeledField`) and existing `KeycapView` — do not build new primitives.

---

## Task 1: `Chord.configToken`

The `keybind =` writer needs the word form of a chord (`cmd+shift+p`) — the inverse of `Chord.parse`. `Chord` already has `displayGlyph` (the glyph form); this mirrors it in config words.

**Files:**
- Modify: `Sources/ZenTerm/Chord.swift`
- Test: `Tests/ZenTermTests/ChordTests.swift`

**Interfaces:**
- Produces: `Chord.configToken: String` — e.g. `Chord(command: true, shift: true, key: "p").configToken == "cmd+shift+p"`. Round-trips: `Chord.parse(c.configToken) == c` for any valid chord.

- [ ] **Step 1: Write the failing test**

Add to `Tests/ZenTermTests/ChordTests.swift`:

```swift
func test_configToken_roundTripsWithParse() {
    let chords = [
        Chord(command: true, shift: true, key: "p"),
        Chord(command: true, key: ","),
        Chord(command: true, shift: true, key: "\\"),
        Chord(command: true, shift: true, key: "|"),
        Chord(option: true, control: true, key: "5"),
    ]
    for chord in chords {
        XCTAssertEqual(chord.configToken, expectedToken(chord))
        XCTAssertEqual(Chord.parse(chord.configToken), chord)
    }
}

private func expectedToken(_ c: Chord) -> String {
    var t = ""
    if c.command { t += "cmd+" }
    if c.shift { t += "shift+" }
    if c.option { t += "opt+" }
    if c.control { t += "ctrl+" }
    return t + c.key
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChordTests/test_configToken_roundTripsWithParse`
Expected: FAIL — `value of type 'Chord' has no member 'configToken'` (compile error).

- [ ] **Step 3: Add `configToken`**

In `Sources/ZenTerm/Chord.swift`, after `displayGlyph` (around line 68), add:

```swift
/// The config-file word form the writer emits (`cmd+shift+g`) — modifiers in the
/// repo's order (cmd, shift, opt, ctrl) then the key. The inverse of `parse`, mirroring
/// `displayGlyph`'s glyph form.
var configToken: String {
    var token = ""
    if command { token += "cmd+" }
    if shift { token += "shift+" }
    if option { token += "opt+" }
    if control { token += "ctrl+" }
    return token + key
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ChordTests/test_configToken_roundTripsWithParse`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/Chord.swift Tests/ZenTermTests/ChordTests.swift
git commit -m "Add Chord.configToken (config-file word form)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `ConfigWriter` scalar path

The net-new writer's scalar half: set a `key = value` in place (preserving a trailing comment), insert after a commented default, append when absent, and remove (reset-to-default). Same safety guards as `WorkspacesWriter` (unreadable → throw without clobber; atomic write through the symlink target).

**Files:**
- Create: `Sources/ZenTerm/ConfigWriter.swift`
- Test: `Tests/ZenTermTests/ConfigWriterTests.swift`

**Interfaces:**
- Produces: `ConfigWriter.apply(scalars:removals:keybinds:configRoot:) throws` where
  `scalars: [String: String] = [:]`, `removals: Set<String> = []`,
  `keybinds: [Chord: KeyInterceptor.ReservedChord]? = nil`,
  `configRoot: URL = ConfigLoader.defaultRoot`. Writes `configRoot/config`. This task
  implements the scalar/removal handling and the file read-modify-atomic-write skeleton;
  `keybinds` is accepted but handled in Task 3 (pass `nil` for now — add the private
  `applyKeybinds` call as a stub that does nothing until Task 3).

- [ ] **Step 1: Write the failing tests**

Create `Tests/ZenTermTests/ConfigWriterTests.swift`:

```swift
import XCTest

@testable import ZenTerm

final class ConfigWriterTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-config-writer-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func seed(_ text: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    private func read(_ dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)
    }

    func test_scalarSet_replacesActiveValue_preservingTrailingComment() throws {
        let dir = try makeTempDir()
        try seed("font-size = 14   # points; clamped to 6…72\n", in: dir)
        try ConfigWriter.apply(scalars: ["font-size": "15"], configRoot: dir)
        XCTAssertEqual(try read(dir), "font-size = 15  # points; clamped to 6…72\n")
    }

    func test_scalarSet_insertsAfterCommentedDefault() throws {
        let dir = try makeTempDir()
        try seed("# Terminal\n# font-size = 14   # points\n", in: dir)
        try ConfigWriter.apply(scalars: ["font-size": "18"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# Terminal\n# font-size = 14   # points\nfont-size = 18\n")
    }

    func test_scalarSet_appendsWhenAbsent() throws {
        let dir = try makeTempDir()
        try seed("# just a comment\n", in: dir)
        try ConfigWriter.apply(scalars: ["theme": "gruvbox"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# just a comment\ntheme = gruvbox\n")
    }

    func test_scalarSet_createsFileWhenAbsent() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(scalars: ["theme": "gruvbox"], configRoot: dir)
        XCTAssertEqual(try read(dir), "theme = gruvbox\n")
    }

    func test_removal_deletesActiveLine() throws {
        let dir = try makeTempDir()
        try seed("# font-size = 14\nfont-size = 20\ntheme = gruvbox\n", in: dir)
        try ConfigWriter.apply(removals: ["font-size"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# font-size = 14\ntheme = gruvbox\n")
    }

    func test_preservesUnknownKeysAndBlankLines() throws {
        let dir = try makeTempDir()
        let original = "# header\n\nunknown-key = keepme\n\ntheme = old\n"
        try seed(original, in: dir)
        try ConfigWriter.apply(scalars: ["theme": "new"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# header\n\nunknown-key = keepme\n\ntheme = new\n")
    }

    func test_roundTripsThroughParser() throws {
        let dir = try makeTempDir()
        try seed("# comment\n", in: dir)
        try ConfigWriter.apply(scalars: ["font-size": "16", "backdrop-alpha": "0.5"], configRoot: dir)
        let parsed = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(parsed.fontSize, 16)
        XCTAssertEqual(parsed.backdropAlpha, 0.5)
    }

    func test_unreadableExistingFile_throwsWithoutClobbering() throws {
        let dir = try makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config")
        let garbage = Data([0xFF, 0xFE, 0xFF])
        try garbage.write(to: url)
        XCTAssertThrowsError(try ConfigWriter.apply(scalars: ["theme": "x"], configRoot: dir))
        XCTAssertEqual(try Data(contentsOf: url), garbage)  // byte-identical: not clobbered
    }

    func test_writesThroughSymlink() throws {
        let dir = try makeTempDir()
        let target = try makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let realFile = target.appendingPathComponent("real-config")
        try "theme = old\n".write(to: realFile, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

        try ConfigWriter.apply(scalars: ["theme": "new"], configRoot: dir)

        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)  // link intact
        XCTAssertEqual(try String(contentsOf: realFile, encoding: .utf8), "theme = new\n")  // wrote target
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigWriterTests`
Expected: FAIL — `cannot find 'ConfigWriter' in scope`.

- [ ] **Step 3: Create `ConfigWriter` (scalar path + skeleton)**

Create `Sources/ZenTerm/ConfigWriter.swift`:

```swift
import Foundation

/// Edits the flat `~/.config/zen-term/config` file in place — the counterpart to
/// `GeneralConfigParser`. Unlike `WorkspacesWriter` (which appends whole `[Title]`
/// sections), `config` is `key = value`, so editing updates keys in place while
/// preserving comments, blank lines, and unknown keys verbatim. Round-trip:
/// `GeneralConfigParser.parse(apply(edits))` reflects every edit; untouched lines survive.
enum ConfigWriter {
    /// Apply scalar sets, scalar removals (reset-to-default), and/or a keymap override
    /// set to the `config` file. Reads the whole file and rewrites it atomically (an atomic
    /// write replaces, so there's no in-place append), preserving every unedited line.
    static func apply(
        scalars: [String: String] = [:],
        removals: Set<String> = [],
        keybinds: [Chord: KeyInterceptor.ReservedChord]? = nil,
        configRoot: URL = ConfigLoader.defaultRoot
    ) throws {
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let url = configRoot.appendingPathComponent("config")
        // If the file exists but can't be read, propagate — never treat an unreadable file as
        // empty, or the whole-file rewrite below would erase the user's config.
        let existing =
            FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8) : ""

        var lines = splitLines(existing)
        for (key, value) in scalars { setScalar(key, value, in: &lines) }
        for key in removals { removeScalar(key, in: &lines) }
        if let keybinds { applyKeybinds(keybinds, to: &lines) }

        var output = lines.joined(separator: "\n")
        if !output.isEmpty { output += "\n" }  // config files end with a trailing newline
        // Write to the symlink's target, not over the symlink — a config symlinked into a
        // dotfiles repo must keep pointing there.
        try output.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
    }

    /// Split into lines with the final trailing newline stripped, so a rejoin + single "\n"
    /// reproduces the file exactly (and an empty file yields no lines, not `[""]`).
    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var body = text
        if body.hasSuffix("\n") { body.removeLast() }
        return body.components(separatedBy: "\n")
    }

    // MARK: scalars

    private static func setScalar(_ key: String, _ value: String, in lines: inout [String]) {
        let rendered = "\(key) = \(value)"
        if let index = lines.firstIndex(where: { activeAssignmentKey($0) == key }) {
            // Preserve any trailing comment on the existing active line.
            if let comment = trailingComment(of: lines[index]) {
                lines[index] = "\(rendered)  \(comment)"
            } else {
                lines[index] = rendered
            }
            return
        }
        if let index = lines.firstIndex(where: { commentedAssignmentKey($0) == key }) {
            lines.insert(rendered, at: index + 1)
            return
        }
        lines.append(rendered)
    }

    private static func removeScalar(_ key: String, in lines: inout [String]) {
        lines.removeAll { activeAssignmentKey($0) == key }
    }

    // MARK: keybinds (implemented in Task 3)

    private static func applyKeybinds(
        _ keybinds: [Chord: KeyInterceptor.ReservedChord], to lines: inout [String]
    ) {
        // Task 3 fills this in.
    }

    // MARK: line classification

    /// The key of an uncommented `key = value` assignment line, else nil (comments, blanks,
    /// prose). Rejects a key containing whitespace so a prose line with a stray `=` never matches.
    static func activeAssignmentKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        return key
    }

    /// The key of a commented-out assignment (`# key = default`), else nil. Same whitespace
    /// guard keeps a prose comment like `# switch = fast` from being read as a default.
    private static func commentedAssignmentKey(_ line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        trimmed.removeFirst()
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        return key
    }

    /// A trailing `# comment` on an active line (quote-aware — a `#` inside quotes isn't a
    /// comment), including the `#`; nil if none. Mirrors `GeneralConfigParser.stripComment`.
    private static func trailingComment(of line: String) -> String? {
        var inQuotes = false
        var previousWasSpace = true
        for index in line.indices {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            if character == "#", !inQuotes, previousWasSpace { return String(line[index...]) }
            previousWasSpace = character.isWhitespace
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigWriterTests`
Expected: PASS (all scalar/guard tests green).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/ConfigWriter.swift Tests/ZenTermTests/ConfigWriterTests.swift
git commit -m "Add ConfigWriter scalar path (in-place edits, reset, safety guards)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `ConfigWriter` keybind path

Regenerate the `keybind =` block from a desired reserved keymap — emitting only bindings that differ from `KeymapDefaults.map`, preserving any hand-written `keybind = toggle_float:…` lines, and placing the block at the anchor. Resetting all overrides removes every reserved `keybind =` line.

**Files:**
- Modify: `Sources/ZenTerm/ConfigWriter.swift`
- Test: `Tests/ZenTermTests/ConfigWriterTests.swift`

**Interfaces:**
- Consumes: `Chord.configToken` (Task 1); `KeyInterceptor.ReservedChord.actionToken`, `KeymapDefaults.map` (existing).
- Produces: the `keybinds:` argument of `ConfigWriter.apply` now regenerates the reserved `keybind =` block. Caller passes the full intended reserved keymap (`[Chord: ReservedChord]`, no float toggles); the writer diffs against defaults.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ZenTermTests/ConfigWriterTests.swift`:

```swift
func test_keybind_emitsOnlyNonDefaultOverrides() throws {
    let dir = try makeTempDir()
    try seed("# ─── Keybinds ───\n", in: dir)
    // Move the command palette to cmd+shift+o; keep everything else at its default.
    var desired = KeymapDefaults.map
    desired = desired.filter { $0.value != .toggleCommandPalette }  // drop its default chord
    desired[Chord(command: true, shift: true, key: "o")] = .toggleCommandPalette
    try ConfigWriter.apply(keybinds: desired, configRoot: dir)
    let text = try read(dir)
    XCTAssertTrue(text.contains("keybind = toggle_command_palette=cmd+shift+o"), text)
    // No other action changed → exactly one keybind line.
    XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("keybind = ") }.count, 1)
}

func test_keybind_resetAll_removesReservedKeybindLines() throws {
    let dir = try makeTempDir()
    try seed("theme = x\nkeybind = toggle_zoom=cmd+shift+z\n", in: dir)
    try ConfigWriter.apply(keybinds: KeymapDefaults.map, configRoot: dir)  // all defaults → no overrides
    let text = try read(dir)
    XCTAssertFalse(text.contains("keybind = "), text)
    XCTAssertTrue(text.contains("theme = x"), text)
}

func test_keybind_preservesFloatKeybindLines() throws {
    let dir = try makeTempDir()
    try seed("keybind = toggle_float:dev=cmd+shift+d\nkeybind = toggle_zoom=cmd+shift+z\n", in: dir)
    try ConfigWriter.apply(keybinds: KeymapDefaults.map, configRoot: dir)  // reset reserved to defaults
    let text = try read(dir)
    XCTAssertTrue(text.contains("keybind = toggle_float:dev=cmd+shift+d"), text)  // float bind kept
    XCTAssertFalse(text.contains("toggle_zoom"), text)  // reserved override dropped
}

func test_keybind_leavesFloatDefinitionLinesUntouched() throws {
    let dir = try makeTempDir()
    try seed("float = id:dev command:\"npm run dev\" key:cmd+shift+d\n", in: dir)
    var desired = KeymapDefaults.map.filter { $0.value != .toggleZoom }
    desired[Chord(command: true, shift: true, key: "z")] = .toggleZoom
    try ConfigWriter.apply(keybinds: desired, configRoot: dir)
    let text = try read(dir)
    XCTAssertTrue(text.contains("float = id:dev command:\"npm run dev\" key:cmd+shift+d"), text)
}

func test_keybind_roundTripsThroughAssembler() throws {
    let dir = try makeTempDir()
    var desired = KeymapDefaults.map.filter { $0.value != .toggleZoom }
    desired[Chord(command: true, shift: true, key: "z")] = .toggleZoom
    try ConfigWriter.apply(keybinds: desired, configRoot: dir)
    let keymap = ConfigLoader.loadGeneralConfig(configRoot: dir).keymap
    XCTAssertEqual(keymap[Chord(command: true, shift: true, key: "z")], .toggleZoom)
    XCTAssertNil(keymap[Chord(command: true, key: "f")])  // old ⌘F default was dropped
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigWriterTests`
Expected: FAIL — the new keybind tests fail (the `applyKeybinds` stub does nothing).

- [ ] **Step 3: Implement `applyKeybinds`**

In `Sources/ZenTerm/ConfigWriter.swift`, replace the stub `applyKeybinds` with:

```swift
/// Regenerate the reserved `keybind =` block from the desired keymap. Emits a line only for a
/// binding that differs from `KeymapDefaults.map` (a default needs no line); preserves existing
/// `keybind = toggle_float:…` lines (float-owned, edited only via `float =`); and drops every
/// other existing `keybind =` line. The block lands where the first `keybind =` line was; if
/// there were none, after the `Keybinds` header comment, else appended.
private static func applyKeybinds(
    _ keybinds: [Chord: KeyInterceptor.ReservedChord], to lines: inout [String]
) {
    let floatBinds = lines.filter(isFloatKeybindLine)
    let overrides =
        keybinds
        .filter { chord, action in KeymapDefaults.map[chord] != action }
        .map { chord, action in "keybind = \(action.actionToken)=\(chord.configToken)" }
        .sorted()
    let block = floatBinds + overrides

    var result: [String] = []
    var inserted = false
    for line in lines {
        if isKeybindLine(line) {
            if !inserted {
                result.append(contentsOf: block)
                inserted = true
            }
            continue  // drop every existing keybind line (block re-adds the ones we keep)
        }
        result.append(line)
    }
    if !inserted, !block.isEmpty {
        if let headerIndex = result.firstIndex(where: { $0.contains("─── Keybinds") }) {
            result.insert(contentsOf: block, at: headerIndex + 1)
        } else {
            if let last = result.last, !last.isEmpty { result.append("") }
            result.append(contentsOf: block)
        }
    }
    lines = result
}

private static func isKeybindLine(_ line: String) -> Bool { activeAssignmentKey(line) == "keybind" }

private static func isFloatKeybindLine(_ line: String) -> Bool {
    guard isKeybindLine(line), let equals = line.firstIndex(of: "=") else { return false }
    let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    return value.hasPrefix("toggle_float:")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigWriterTests`
Expected: PASS (all scalar + keybind tests green).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/ConfigWriter.swift Tests/ZenTermTests/ConfigWriterTests.swift
git commit -m "Add ConfigWriter keybind block regen (float-safe, diff vs defaults)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `AppConfig` reload seam

Make `GeneralConfig.current` / `Theme.current` re-resolvable and broadcast a change so living consumers react. Wire PR1's single consumer: the keymap.

**Files:**
- Create: `Sources/ZenTerm/AppConfig.swift`
- Modify: `Sources/ZenTerm/GeneralConfig.swift:72`, `Sources/ZenTerm/Theme.swift:27`, `Sources/ZenTerm/AppDelegate.swift`

**Interfaces:**
- Produces: `AppConfig.reload()` (re-resolves both statics, then posts `Notification.Name.configDidChange`); `GeneralConfig.reloadCurrent()`; `Theme.reloadCurrent()`; `Notification.Name.configDidChange`.
- Consumes: `ConfigLoader.loadGeneralConfig()`, `ConfigLoader.loadAppTheme()` (existing).

- [ ] **Step 1: Flip the statics to reloadable vars**

In `Sources/ZenTerm/GeneralConfig.swift`, replace line 72:

```swift
static let current: GeneralConfig = ConfigLoader.loadGeneralConfig()
```

with:

```swift
/// The resolved config for this launch, re-resolvable via `reloadCurrent()` when the Settings
/// card writes the file (see `AppConfig.reload()`). External hand-edits still need a relaunch.
static private(set) var current: GeneralConfig = ConfigLoader.loadGeneralConfig()

/// Re-read `config` from disk and swap `current`. Called by `AppConfig.reload()` after a write.
static func reloadCurrent() { current = ConfigLoader.loadGeneralConfig() }
```

In `Sources/ZenTerm/Theme.swift`, replace line 27:

```swift
static let current: AppTheme = ConfigLoader.loadAppTheme()
```

with:

```swift
/// The resolved appearance for this launch, re-resolvable via `reloadCurrent()`. Reads the
/// general config for the font, so `GeneralConfig.reloadCurrent()` must run first.
static private(set) var current: AppTheme = ConfigLoader.loadAppTheme()

/// Re-read the theme (and font from the general config) and swap `current`.
static func reloadCurrent() { current = ConfigLoader.loadAppTheme() }
```

- [ ] **Step 2: Create `AppConfig`**

Create `Sources/ZenTerm/AppConfig.swift`:

```swift
import Foundation

extension Notification.Name {
    /// Posted after `AppConfig.reload()` re-resolves the config statics, so living consumers
    /// (the keymap now; chrome layout and terminal surfaces in later PRs) re-apply.
    static let configDidChange = Notification.Name("ZenTerm.configDidChange")
}

/// The save→reload→apply seam. After the Settings card writes `config` via `ConfigWriter`,
/// `reload()` re-resolves the launch statics from disk (general first, then theme, which reads
/// the general font) and broadcasts `configDidChange`. The invariant: after any write + reload,
/// `GeneralConfig.current` / `Theme.current` mirror the file.
enum AppConfig {
    static func reload() {
        GeneralConfig.reloadCurrent()
        Theme.reloadCurrent()
        NotificationCenter.default.post(name: .configDidChange, object: nil)
    }
}
```

- [ ] **Step 3: Wire the keymap consumer in `AppDelegate`**

In `Sources/ZenTerm/AppDelegate.swift`, inside `applicationDidFinishLaunching`, after the existing `keys.start()` (line 31), add:

```swift
// The one live consumer in PR1: when config changes (a keybind edit in the Settings card),
// rebuild the interceptor's keymap so the rebind takes effect with no relaunch.
NotificationCenter.default.addObserver(
    forName: .configDidChange, object: nil, queue: .main
) { [weak self] _ in
    self?.keys.setKeymap(GeneralConfig.current.keymap)
}
```

- [ ] **Step 4: Verify build + full test suite**

Run: `swift build && swift test`
Expected: build succeeds; all existing tests still pass (the `static let` → `static private(set) var` change is source-compatible — every read site is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/AppConfig.swift Sources/ZenTerm/GeneralConfig.swift Sources/ZenTerm/Theme.swift Sources/ZenTerm/AppDelegate.swift
git commit -m "Add AppConfig.reload save→reload→apply seam; wire keymap consumer

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `KeyboardFocus` engine

Extract the reusable traversal mechanics from `AddWorkspaceOverlay` so the Settings card runs the identical feel. `verticalStops()` stays per-overlay (each card's rows differ); the field-editor-aware focus check and the clamp/step math lift out.

**Files:**
- Create: `Sources/ZenTerm/KeyboardFocus.swift`
- Modify: `Sources/ZenTerm/AddWorkspaceOverlay.swift:237-269` (use the shared helpers)
- Test: `Tests/ZenTermTests/KeyboardFocusTests.swift`

**Interfaces:**
- Produces: `KeyboardFocus.isFocused(_ view: NSView, in window: NSWindow?) -> Bool`; `KeyboardFocus.step(from: Int?, delta: Int, count: Int) -> Int?`.
- Consumed by: `AddWorkspaceOverlay` (this task) and `SettingsOverlay` (Task 7).

- [ ] **Step 1: Write the failing test**

Create `Tests/ZenTermTests/KeyboardFocusTests.swift`:

```swift
import XCTest

@testable import ZenTerm

final class KeyboardFocusTests: XCTestCase {
    func test_step_movesAndClampsAtEnds() {
        XCTAssertEqual(KeyboardFocus.step(from: 0, delta: 1, count: 3), 1)
        XCTAssertEqual(KeyboardFocus.step(from: 2, delta: 1, count: 3), nil)  // clamp at end
        XCTAssertEqual(KeyboardFocus.step(from: 0, delta: -1, count: 3), nil)  // clamp at start
        XCTAssertEqual(KeyboardFocus.step(from: 1, delta: -1, count: 3), 0)
    }

    func test_step_noAnchor_jumpsToEnd() {
        XCTAssertEqual(KeyboardFocus.step(from: nil, delta: 1, count: 3), 0)   // first
        XCTAssertEqual(KeyboardFocus.step(from: nil, delta: -1, count: 3), 2)  // last
    }

    func test_step_emptyStops_isNil() {
        XCTAssertNil(KeyboardFocus.step(from: nil, delta: 1, count: 0))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter KeyboardFocusTests`
Expected: FAIL — `cannot find 'KeyboardFocus' in scope`.

- [ ] **Step 3: Create `KeyboardFocus`**

Create `Sources/ZenTerm/KeyboardFocus.swift`:

```swift
import AppKit

/// The shared 2D keyboard-focus mechanics for the modal cards (`AddWorkspaceOverlay`,
/// `SettingsOverlay`). Each card supplies its own vertical stop list — the rows differ — but
/// the first-responder check and the clamp/step math are identical, so they live here.
enum KeyboardFocus {
    /// Whether `view` currently holds first responder, resolving a text field's field editor
    /// (the actual responder while editing) back to the field itself.
    static func isFocused(_ view: NSView, in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSTextField {
            return field === view
        }
        return responder === view
    }

    /// The next index when stepping `delta` from `from` within `count` stops, clamped at the
    /// ends (nil = no move). With no anchor (`from == nil`), a forward step lands on the first
    /// stop and a backward step on the last.
    static func step(from: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let from else { return delta > 0 ? 0 : count - 1 }
        let next = from + delta
        return (0..<count).contains(next) ? next : nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter KeyboardFocusTests`
Expected: PASS.

- [ ] **Step 5: Refactor `AddWorkspaceOverlay` to use the shared helpers**

In `Sources/ZenTerm/AddWorkspaceOverlay.swift`, replace `moveVertical` (lines 237-248) and `isFocused` (lines 263-269) so both route through `KeyboardFocus`. Replace `moveVertical`:

```swift
private func moveVertical(_ delta: Int) {
    let stops = verticalStops()
    let anchor = currentVerticalAnchor(in: stops).flatMap { anchor in stops.firstIndex { $0 === anchor } }
    guard let next = KeyboardFocus.step(from: anchor, delta: delta, count: stops.count) else { return }
    window?.makeFirstResponder(stops[next])
}
```

Replace `isFocused`:

```swift
private func isFocused(_ view: NSView) -> Bool { KeyboardFocus.isFocused(view, in: window) }
```

- [ ] **Step 6: Verify build + AddWorkspace behavior preserved**

Run: `swift build && swift test`
Expected: build + all tests green. (Behavior-preserving; the Add-Workspace form's keyboard nav is unchanged — its runbook re-verified in Task 9.)

- [ ] **Step 7: Commit**

```bash
git add Sources/ZenTerm/KeyboardFocus.swift Tests/ZenTermTests/KeyboardFocusTests.swift Sources/ZenTerm/AddWorkspaceOverlay.swift
git commit -m "Extract KeyboardFocus engine; route AddWorkspaceOverlay through it

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `openSettings` action + command-palette entry

Add the new reserved action, its config token, its default `cmd+,` binding, and its "Settings…" command-palette entry. Exhaustive switches force every site to be updated for the build to pass.

**Files:**
- Modify: `Sources/ZenTerm/KeyInterceptor.swift:8-24`, `Sources/ZenTerm/Keybinds.swift`, `Sources/ZenTerm/CommandCatalog.swift`
- Test: `Tests/ZenTermTests/CommandCatalogTests.swift`, `Tests/ZenTermTests/KeybindParserTests.swift`

**Interfaces:**
- Produces: `KeyInterceptor.ReservedChord.openSettings`; `actionToken == "open_settings"`; `KeymapDefaults.map` includes `Chord(command: true, key: ",") → .openSettings`; `CommandCatalog` "Settings…" entry (Tools).

- [ ] **Step 1: Update the command-palette test (failing)**

In `Tests/ZenTermTests/CommandCatalogTests.swift`, update the expected list in `test_baseCommands_orderAndCount` — insert `"Settings…"` right after `"Add Workspace…"`:

```swift
        XCTAssertEqual(
            names,
            [
                "Open Workspace Picker", "Add Workspace…", "Settings…", "Open Lazygit",
                "Toggle Bottom Drawer", "Toggle Right Drawer",
                "New Tab", "Previous Tab", "Next Tab",
                "Split Horizontally", "Split Vertically",
                "Focus Pane Left", "Focus Pane Down", "Focus Pane Up", "Focus Pane Right",
                "Resize Pane Left", "Resize Pane Down", "Resize Pane Up", "Resize Pane Right",
                "Toggle Zoom", "Close Pane",
            ])
```

In `Tests/ZenTermTests/KeybindParserTests.swift`, add `.openSettings` to the `cases` array in `test_actionToken_roundTripsEveryCase` (after `.toggleCommandPalette`):

```swift
            .toggleRepoPicker, .toggleCommandPalette, .openSettings,
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CommandCatalogTests`
Expected: FAIL — `type 'KeyInterceptor.ReservedChord' has no member 'openSettings'` (compile error).

- [ ] **Step 3: Add the enum case**

In `Sources/ZenTerm/KeyInterceptor.swift`, add to the `ReservedChord` enum after `case addWorkspace` (line 23):

```swift
        case openSettings
```

- [ ] **Step 4: Add the token + default binding**

In `Sources/ZenTerm/Keybinds.swift`, in `actionToken` after the `.addWorkspace` case (line 31):

```swift
        case .openSettings: return "open_settings"
```

In `init?(token:)` after the `.addWorkspace` case (line 60):

```swift
        case "open_settings": self = .openSettings
```

In `KeymapDefaults.map`, in the bare-⌘ block after the `.toggleCommandPalette` line (line 106):

```swift
        map[Chord(command: true, key: ",")] = .openSettings
```

- [ ] **Step 5: Add the command-palette entry**

In `Sources/ZenTerm/CommandCatalog.swift`, in `spec(for:)` after the `.addWorkspace` case (line 50):

```swift
        case .openSettings: return tool("Settings…", glyph, chord)
```

In `commands(tabCount:)`, add `.openSettings` to the first Tools group (line 66-68):

```swift
        var chords: [KeyInterceptor.ReservedChord] = [
            .toggleRepoPicker, .addWorkspace, .openSettings, .toggleLazygit,
        ]
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter CommandCatalogTests && swift test --filter KeybindParserTests`
Expected: PASS. `test_everyEntry_hasTitle_andBoundEntriesHaveShortcut` passes because `.openSettings` is bound (`⌘,`) and shows a glyph.

- [ ] **Step 7: Commit**

```bash
git add Sources/ZenTerm/KeyInterceptor.swift Sources/ZenTerm/Keybinds.swift Sources/ZenTerm/CommandCatalog.swift Tests/ZenTermTests/CommandCatalogTests.swift Tests/ZenTermTests/KeybindParserTests.swift
git commit -m "Add openSettings reserved action + Settings… palette entry (⌘,)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `SettingsOverlay` shell + modal plumbing

A `ModalOverlay` with a left nav ↔ right detail split, presented through the existing single-slot machinery. Registers one section (Keybinds) — a minimal placeholder detail here; Task 8 fills in the editor. Verified by running the app (GUI; no unit seam, like the other overlays).

**Files:**
- Create: `Sources/ZenTerm/SettingsOverlay.swift`, `Sources/ZenTerm/SettingsSection.swift`, `Sources/ZenTerm/SettingsNavRow.swift`, `Sources/ZenTerm/SettingsKeybindsSection.swift` (placeholder)
- Modify: `Sources/ZenTerm/KeyInterceptor.swift` (chord-capture seam + `KeybindCapturing`), `Sources/ZenTerm/WindowController.swift` (ModalKind + openSettings + gates + dispatch + `keybindCapturer`), `Sources/ZenTerm/AppDelegate.swift` (inject `keys` as capturer)

**Interfaces:**
- Consumes: `ModalOverlay`, `BackdropView`, `CardView` (`ModalCard.swift`); `FloatShadow`; `Motion.springScaleFade`; `Theme.current.chrome`; `KeyboardFocus` (Task 5).
- Produces: `protocol SettingsSection: AnyObject { var navTitle: String { get }; func makeDetailView() -> NSView; func detailStops() -> [NSView] }`; `SettingsOverlay(sections:background:onClose:)`; `WindowController.openSettings()`.

- [ ] **Step 1: Define the section protocol**

Create `Sources/ZenTerm/SettingsSection.swift`:

```swift
import AppKit

/// One Settings card section: a nav title and a detail view. The card owns nav selection and
/// focus routing; a section supplies its editor and the ordered vertical focus stops within it.
/// PR1 registers only `SettingsKeybindsSection`; later PRs add Terminal, Theme, Layout & Motion.
protocol SettingsSection: AnyObject {
    var navTitle: String { get }
    /// Set by the card: the section calls this when focus should leave the detail pane's first
    /// stop and return to the nav (Left / Shift-Tab), completing the 2D nav ↔ detail model.
    var onExitToNav: (() -> Void)? { get set }
    func makeDetailView() -> NSView
    /// The detail pane's vertical focus stops, top to bottom (for the shared 2D keyboard model).
    func detailStops() -> [NSView]
}
```

- [ ] **Step 2: Create the placeholder Keybinds section**

Create `Sources/ZenTerm/SettingsKeybindsSection.swift`:

```swift
import AppKit

/// The Keybinds settings section: remap the built-in actions. Task 8 fleshes out the editor;
/// this scaffold gives the shell a registered section so the card opens with a working nav.
final class SettingsKeybindsSection: SettingsSection {
    var navTitle: String { "Keybinds" }
    var onExitToNav: (() -> Void)?

    func makeDetailView() -> NSView {
        let label = NSTextField(labelWithString: "Keybinds")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    func detailStops() -> [NSView] { [] }
}
```

> Note: Task 8 replaces this file with the real editor (which takes a `capturer:` in its init). The placeholder has no initializer args, so Task 7's `openSettings()` builds it as `SettingsKeybindsSection()`; Task 8 updates that call site to pass the capturer.

- [ ] **Step 3: Create the `SettingsOverlay` shell**

Create `Sources/ZenTerm/SettingsOverlay.swift`. Mirror `AddWorkspaceOverlay`'s `ModalOverlay` scaffold (backdrop + `CardView` + `FloatShadow` + `Motion.springScaleFade`), but lay out a horizontal nav/detail split. Complete implementation:

```swift
import AppKit

/// The Settings card — a `ModalOverlay` like the palettes (shared card + backdrop + spring), with
/// a left nav of sections and a right detail pane. Fully keyboard-driven: Up/Down move within the
/// nav, Right/Tab enter the detail pane, Left/Shift-Tab off the first detail stop return to the
/// nav, Esc closes. Config edits in each section apply live (no restart).
final class SettingsOverlay: NSView, ModalOverlay {
    private let sections: [SettingsSection]
    private let capturer: KeybindCapturing?
    private let onClose: () -> Void

    private let card = CardView()
    private var isDismissing = false

    private let navStack = NSStackView()
    private var navRows: [SettingsNavRow] = []
    private let detailContainer = NSView()
    private var selectedIndex = 0

    init(
        sections: [SettingsSection], capturer: KeybindCapturing?, background: NSColor,
        onClose: @escaping () -> Void
    ) {
        self.sections = sections
        self.capturer = capturer
        self.onClose = onClose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: onClose)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = FloatShadow.edge.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        FloatShadow.applyShadow(to: card)

        let content = buildContent()
        card.addSubview(content)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 620),
            card.heightAnchor.constraint(equalToConstant: 460),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.92),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.92),

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        selectSection(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: ModalOverlay

    func focusInitialResponder() {
        if let first = navRows.first { window?.makeFirstResponder(first) }
    }
    func animateIn() {
        superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(card, appearing: true)
    }
    func animateOut(completion: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        capturer?.endCapture()  // never leave a capture handler armed after the card closes
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { isDismissing ? nil : super.hitTest(point) }

    // MARK: content

    private func buildContent() -> NSView {
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 2
        navStack.edgeInsets = NSEdgeInsets(top: 18, left: 12, bottom: 16, right: 12)
        for (index, section) in sections.enumerated() {
            section.onExitToNav = { [weak self] in self?.focusNav() }
            let row = SettingsNavRow(title: section.navTitle) { [weak self] in self?.selectSection(index) }
            row.onArrowUp = { [weak self] in self?.moveNav(-1) }
            row.onArrowDown = { [weak self] in self?.moveNav(1) }
            row.onEnterDetail = { [weak self] in self?.enterDetail() }
            row.onEsc = { [weak self] in self?.onClose() }
            navRows.append(row)
            navStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: navStack.widthAnchor, constant: -24).isActive = true
        }

        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        navStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(navStack)
        root.addSubview(divider)
        root.addSubview(detailContainer)
        NSLayoutConstraint.activate([
            navStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navStack.topAnchor.constraint(equalTo: root.topAnchor),
            navStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            navStack.widthAnchor.constraint(equalToConstant: 168),

            divider.leadingAnchor.constraint(equalTo: navStack.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            detailContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: root.topAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    // MARK: selection + focus

    private func selectSection(_ index: Int) {
        guard sections.indices.contains(index) else { return }
        selectedIndex = index
        for (rowIndex, row) in navRows.enumerated() { row.setSelected(rowIndex == index) }
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let detail = sections[index].makeDetailView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            detail.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
            detail.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 18),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: detailContainer.bottomAnchor, constant: -16),
        ])
        window?.makeFirstResponder(navRows[index])
    }

    private func moveNav(_ delta: Int) {
        let current = navRows.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        guard let next = KeyboardFocus.step(from: current, delta: delta, count: navRows.count) else { return }
        selectSection(next)
    }

    private func enterDetail() {
        guard let first = sections[selectedIndex].detailStops().first else { return }
        window?.makeFirstResponder(first)
    }

    private func focusNav() {
        guard navRows.indices.contains(selectedIndex) else { return }
        window?.makeFirstResponder(navRows[selectedIndex])
    }
}
```

Create the nav row `Sources/ZenTerm/SettingsNavRow.swift`:

```swift
import AppKit

/// One left-nav entry in the Settings card: a selectable, keyboard-focusable label. Selected
/// reads as a muted accent fill; focus is the shared 2D model (Up/Down move, Right/Tab enter
/// the detail pane, Esc closes).
final class SettingsNavRow: NSView {
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onEnterDetail: (() -> Void)?
    var onEsc: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let onActivate: () -> Void
    private var isSelected = false
    private var isFocusedStop = false

    init(title: String, onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        refreshFill()
    }

    private func refreshFill() {
        if isFocusedStop {
            layer?.backgroundColor = Theme.current.chrome.accent.nsColor.withAlphaComponent(0.18).cgColor
        } else if isSelected {
            layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.06).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocusedStop = true; refreshFill(); return true }
    override func resignFirstResponder() -> Bool { isFocusedStop = false; refreshFill(); return true }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onActivate() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: onArrowUp?()        // Up
        case 125: onArrowDown?()      // Down
        case 124, 48: onEnterDetail?()  // Right, Tab
        case 53: onEsc?()             // Esc
        default: super.keyDown(with: event)
        }
    }
}
```

- [ ] **Step 4: Add the chord-capture seam to `KeyInterceptor`**

The global `.keyDown` monitor sees every event before the responder chain, so it would swallow an already-bound chord (⌘P) before a capture UI could read it. Give the interceptor a capture mode: while a handler is set, every keyDown is diverted to it and consumed, bypassing normal routing — so the Keybinds section can record *any* chord.

In `Sources/ZenTerm/KeyInterceptor.swift`, add the capability protocol above the class:

```swift
/// The narrow capability the Settings Keybinds section needs from the key interceptor: divert
/// the next keystrokes to a capture handler instead of routing them, so recording a new chord
/// isn't pre-empted by the chord's current binding.
protocol KeybindCapturing: AnyObject {
    func beginCapture(_ handler: @escaping (NSEvent) -> Void)
    func endCapture()
}
```

Add the stored handler + methods inside `KeyInterceptor` (after `setKeymap`, line 34):

```swift
/// When set (the Settings card is recording), every keyDown is diverted here and consumed,
/// bypassing keymap routing — so even a bound chord (⌘P) is captured, not fired.
private var captureHandler: ((NSEvent) -> Void)?

func beginCapture(_ handler: @escaping (NSEvent) -> Void) { captureHandler = handler }
func endCapture() { captureHandler = nil }
```

In `start()`, add the capture check at the top of the monitor closure, before the chord lookup (line 44):

```swift
monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
    guard let self else { return event }
    if let captureHandler = self.captureHandler {
        captureHandler(event)
        return nil  // consumed — never routes or reaches the PTY while capturing
    }
    guard let chord = Chord(event: event), let action = self.keymap[chord] else { return event }
    self.onReservedChord?(action)
    return nil
}
```

Conform `KeyInterceptor` to the protocol (the methods already satisfy it) — add at the bottom of the file:

```swift
extension KeyInterceptor: KeybindCapturing {}
```

- [ ] **Step 5: Wire the modal plumbing in `WindowController` + `AppDelegate`**

In `Sources/ZenTerm/WindowController.swift`, add `settings` to `ModalKind` (line 42) and its `selfToggle` (line 45-51):

```swift
        case repoPicker, commandPalette, addWorkspace, settings
```
```swift
            case .settings: return .openSettings
```

Add a stored property near the other `WindowController` fields (e.g. below `private var modal` at line 53) — set by `AppDelegate` so the Settings card can record chords through the interceptor:

```swift
/// The app's key interceptor, injected so the Settings Keybinds section can capture chords.
weak var keybindCapturer: KeybindCapturing?
```

Add `.openSettings` to the modal live-switch case (line 562):

```swift
            case .toggleRepoPicker, .toggleCommandPalette, .addWorkspace, .openSettings,
                 .toggleLazygit, .toggleToolFloat:
                closeModal()
```

Add `.openSettings` to the lazygit switch-to case (line 580) and the tool-float switch-to case (line 601):

```swift
            case .toggleToolFloat, .toggleCommandPalette, .toggleRepoPicker, .addWorkspace, .openSettings:
```
(lazygit — keep the trailing `active?.toggleLazygit()`)
```swift
            case .toggleLazygit, .toggleCommandPalette, .toggleRepoPicker, .addWorkspace, .openSettings:
```
(tool-float — keep the trailing `active?.closeToolFloat()`)

Add the dispatch case in the main `switch chord` (after line 637):

```swift
        case .openSettings: openSettings()
```

Add the `openSettings()` method after `openAddWorkspaceForm` (line 453). The placeholder section takes no args yet — Task 8 updates this call to `SettingsKeybindsSection(capturer: keybindCapturer)`:

```swift
/// Open the Settings card. Built fresh each open so every section reads live config values.
private func openSettings() {
    if modal?.kind == .settings { closeModal(); return }
    let overlay = SettingsOverlay(
        sections: [SettingsKeybindsSection()],
        capturer: keybindCapturer,
        background: Theme.current.chrome.background.nsColor,
        onClose: { [weak self] in self?.closeModal() }
    )
    presentModal(overlay, kind: .settings)
}
```

In `Sources/ZenTerm/AppDelegate.swift`, in `newWindow(initialCWD:centered:)`, after `let wc = WindowController(...)` (line 58), inject the interceptor:

```swift
wc.keybindCapturer = keys
```

- [ ] **Step 6: Verify build**

Run: `swift build && swift test`
Expected: build succeeds; all tests green (exhaustive `ModalKind.selfToggle` and `handle` switches now cover `.settings`/`.openSettings`).

- [ ] **Step 7: Manual smoke check**

Run: `swift run ZenTerm`. Press `⌘,` (and separately `⌘P` → "Settings…"). Expected: the card springs in with a "Keybinds" nav row and a "Keybinds" heading in the detail pane; Esc closes it; backdrop click closes it; opening ⌘P while it's up live-switches to the palette. Report the observation (GUI verification requires the user — hand this step to Drew if running headless).

- [ ] **Step 8: Commit**

```bash
git add Sources/ZenTerm/KeyInterceptor.swift Sources/ZenTerm/SettingsOverlay.swift Sources/ZenTerm/SettingsSection.swift Sources/ZenTerm/SettingsNavRow.swift Sources/ZenTerm/SettingsKeybindsSection.swift Sources/ZenTerm/WindowController.swift Sources/ZenTerm/AppDelegate.swift
git commit -m "Add SettingsOverlay shell + chord-capture seam + modal plumbing (⌘,)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Keybinds section editor

Flesh out `SettingsKeybindsSection`: rows of action + current chord + record + reset, press-to-capture with ≥1-modifier and block-on-conflict validation, and per-row / section reset — each committed edit writes via `ConfigWriter` and reloads via `AppConfig` so the rebind is live.

**Files:**
- Modify: `Sources/ZenTerm/SettingsKeybindsSection.swift` (replace the placeholder)
- Create: `Sources/ZenTerm/KeybindRow.swift`
- Modify: `Sources/ZenTerm/Controls/AppButton.swift` (mutable title — see the note in Step 1)
- Modify: `Sources/ZenTerm/WindowController.swift` (pass `capturer:` to the section)

**Interfaces:**
- Consumes: `ConfigWriter.apply(keybinds:)` (Tasks 2-3); `AppConfig.reload()` (Task 4); `GeneralConfig.current.keymap`, `KeymapDefaults.map`, `KeyInterceptor.ReservedChord` + `actionToken` (existing); `Chord(event:)`, `displayGlyph` (existing); `CommandCatalog.spec(for:)` for conflict names; `KeycapView`, `AppButton` (existing); `KeyboardFocus` (Task 5).
- Produces: a working `detailStops()` (the record control of each row, top to bottom) and live rebinding.

**Model rules (implement exactly):**
- **Editable actions**: every fixed `ReservedChord` except `.toggleToolFloat`. Build the ordered list grouped by category: `[.splitHorizontal, .splitVertical]`, `[.navLeft, .navDown, .navUp, .navRight]`, `[.resizeLeft, .resizeDown, .resizeUp, .resizeRight]`, `[.newTab, .newWindow, .prevTab, .nextTab]` + `.selectTab(1…9)`, `[.toggleBottomDrawer, .toggleRightDrawer, .toggleZoom]`, `[.toggleLazygit, .toggleRepoPicker, .toggleCommandPalette, .addWorkspace, .openSettings]`.
- **Desired map**: `var desired: [Chord: ReservedChord]` initialized to the reserved (non-float) entries of `GeneralConfig.current.keymap`. Each edit passes the whole `desired` to `ConfigWriter.apply(keybinds:)`, then `AppConfig.reload()`, then re-reads `GeneralConfig.current.keymap` to refresh every row's keycap.
- **Displayed chord** for an action: the `desired` entries whose value is that action, taken as the deterministic first when sorted by `configToken`. Most actions have one; `.splitVertical` has two defaults (`|`, `\\`) — showing one is acceptable.
- **Rebind** action A to captured chord C: reject if `C` has fewer than one modifier ("Needs at least one modifier"); reject if `GeneralConfig.current.keymap[C]` is some action B ≠ A (block: "⌘… is already bound to <B's title>", B's title from `CommandCatalog.spec(for: B).title`); else remove every `desired` entry whose value is A, remove any `desired[C]`, set `desired[C] = A`, write + reload + refresh.
- **Reset row** A: remove every `desired` entry whose value is A; re-insert A's default chords from `KeymapDefaults.map` (`KeymapDefaults.map.filter { $0.value == A }`); write + reload + refresh. The reset control is shown only when A's current binding differs from its default.
- **Reset all**: `desired = KeymapDefaults.map.filter { non-float }`; write + reload + refresh.

- [ ] **Step 1: Create the row view**

Create `Sources/ZenTerm/KeybindRow.swift`:

```swift
import AppKit

/// One Keybinds row: the action label, its current chord as a `KeycapView`, a record button, and
/// a reset-to-default button shown only when overridden. The record button is the row's single
/// vertical focus stop; tapping it asks the section to begin capture (through the interceptor).
final class KeybindRow: NSView {
    let action: KeyInterceptor.ReservedChord
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onRecordTapped: (() -> Void)?
    var onReset: (() -> Void)?

    let recordButton = AppButton(title: "Set", variant: .secondary)
    private let resetButton = AppButton(title: "⤺", variant: .muted)
    private let keycapHost = NSView()
    private let messageLabel = NSTextField(labelWithString: "")
    private var hasBinding = false
    private var isCapturing = false

    init(action: KeyInterceptor.ReservedChord, title: String) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        keycapHost.translatesAutoresizingMaskIntoConstraints = false

        recordButton.isKeyboardFocusable = true
        recordButton.onArrowUp = { [weak self] in self?.onArrowUp?() }
        recordButton.onArrowDown = { [weak self] in self?.onArrowDown?() }
        recordButton.onArrowLeft = { [weak self] in self?.onArrowLeft?() }
        recordButton.onTap = { [weak self] in self?.onRecordTapped?() }

        resetButton.onTap = { [weak self] in self?.onReset?() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [label, spacer, keycapHost, recordButton, resetButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        messageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        messageLabel.textColor = Theme.current.chrome.destructive.nsColor
        messageLabel.isHidden = true

        let stack = NSStackView(views: [controls, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Reflect capturing state on the record button label ("Press keys…" while recording).
    func setCapturing(_ capturing: Bool) {
        isCapturing = capturing
        recordButton.setTitle(recordLabel)
    }

    /// Refresh the keycap, the record button label, and whether the reset control shows.
    func render(currentShortcut: String, isOverridden: Bool) {
        hasBinding = !currentShortcut.isEmpty
        keycapHost.subviews.forEach { $0.removeFromSuperview() }
        if hasBinding {
            let cap = KeycapView(shortcut: currentShortcut)
            cap.translatesAutoresizingMaskIntoConstraints = false
            keycapHost.addSubview(cap)
            NSLayoutConstraint.activate([
                cap.leadingAnchor.constraint(equalTo: keycapHost.leadingAnchor),
                cap.trailingAnchor.constraint(equalTo: keycapHost.trailingAnchor),
                cap.topAnchor.constraint(equalTo: keycapHost.topAnchor),
                cap.bottomAnchor.constraint(equalTo: keycapHost.bottomAnchor),
            ])
        }
        recordButton.setTitle(recordLabel)
        resetButton.isHidden = !isOverridden
    }

    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }

    private var recordLabel: String {
        if isCapturing { return "Press keys…" }
        return hasBinding ? "Change" : "Set"
    }
}
```

> **Note on `AppButton`:** the record button changes its label ("Set" / "Change" / "Press keys…"), which the shared `AppButton` can't do today (`labelText` is a `let` rendered in `restyle()`). Add a mutable title to `Sources/ZenTerm/Controls/AppButton.swift` in this task (a focused addition to the shared primitive, required by the capture flow): change `private let labelText: String` to `private var labelText: String`, and add `func setTitle(_ title: String) { labelText = title; restyle() }`. Verify existing `AppButton` callers still build.

- [ ] **Step 2: Replace the placeholder section with the editor**

Replace `Sources/ZenTerm/SettingsKeybindsSection.swift`:

```swift
import AppKit

/// The Keybinds settings section: remap the built-in actions. Reads the live keymap, captures a
/// new chord per row (press-to-record, ≥1 modifier, block-on-conflict), writes the override set
/// via `ConfigWriter`, and reloads via `AppConfig` so the rebind is live — no restart. Per-row
/// and section reset return bindings to their built-in defaults.
final class SettingsKeybindsSection: SettingsSection {
    var navTitle: String { "Keybinds" }
    var onExitToNav: (() -> Void)?

    /// Editable actions grouped by category (float toggles are excluded — they're file-only).
    private static let groups: [(String, [KeyInterceptor.ReservedChord])] = [
        ("Splits", [.splitHorizontal, .splitVertical]),
        ("Navigation", [.navLeft, .navDown, .navUp, .navRight]),
        ("Resize", [.resizeLeft, .resizeDown, .resizeUp, .resizeRight]),
        ("Tabs", [.newTab, .newWindow, .prevTab, .nextTab] + (1...9).map { .selectTab($0) }),
        ("Drawers", [.toggleBottomDrawer, .toggleRightDrawer, .toggleZoom]),
        ("Surfaces & Tools", [.toggleLazygit, .toggleRepoPicker, .toggleCommandPalette, .addWorkspace, .openSettings]),
    ]

    private let capturer: KeybindCapturing?
    private var desired: [Chord: KeyInterceptor.ReservedChord] = [:]
    private var rows: [KeybindRow] = []

    init(capturer: KeybindCapturing?) { self.capturer = capturer }

    func makeDetailView() -> NSView {
        desired = reservedEntries(of: GeneralConfig.current.keymap)
        rows = []

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Keybinds")
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        stack.addArrangedSubview(header)

        for (category, actions) in Self.groups {
            let caption = NSTextField(labelWithString: category.uppercased())
            caption.font = .systemFont(ofSize: 10, weight: .semibold)
            caption.textColor = Theme.current.chrome.ink(alpha: 0.4)
            stack.addArrangedSubview(caption)
            for action in actions {
                let row = KeybindRow(action: action, title: CommandCatalog.spec(for: action).title)
                row.onArrowUp = { [weak self] in self?.moveRow(from: row, delta: -1) }
                row.onArrowDown = { [weak self] in self?.moveRow(from: row, delta: 1) }
                row.onArrowLeft = { [weak self] in self?.onExitToNav?() }
                row.onRecordTapped = { [weak self] in self?.beginCapture(for: row) }
                row.onReset = { [weak self] in self?.reset(row) }
                rows.append(row)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        let resetAll = AppButton(title: "Reset all to defaults", variant: .muted)
        resetAll.onTap = { [weak self] in self?.resetAll() }
        stack.addArrangedSubview(resetAll)

        // A scroll view keeps the long list inside the fixed card.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        refreshRows()
        return scroll
    }

    func detailStops() -> [NSView] { rows.map(\.recordButton) }

    // MARK: edits

    /// Record the next chord through the interceptor (so an already-bound chord isn't pre-empted),
    /// then rebind. Esc cancels; capture is one-shot (the handler ends it on the first event).
    private func beginCapture(for row: KeybindRow) {
        row.setCapturing(true)
        row.showMessage(nil)
        capturer?.beginCapture { [weak self, weak row] event in
            guard let self, let row else { return }
            self.capturer?.endCapture()
            row.setCapturing(false)
            if event.keyCode == 53 { return }  // Esc cancels — no change
            guard let chord = Chord(event: event) else { return }
            self.rebind(row, to: chord)
        }
    }

    private func rebind(_ row: KeybindRow, to chord: Chord) {
        guard chord.command || chord.shift || chord.option || chord.control else {
            row.showMessage("Needs at least one modifier."); return
        }
        if let owner = GeneralConfig.current.keymap[chord], owner != row.action {
            row.showMessage("\(chord.displayGlyph) is already bound to \(CommandCatalog.spec(for: owner).title).")
            return
        }
        row.showMessage(nil)
        desired = desired.filter { $0.value != row.action }  // drop this action's old chord(s)
        desired[chord] = row.action  // the chord is free — a conflict would have been blocked above
        persist()
    }

    private func reset(_ row: KeybindRow) {
        desired = desired.filter { $0.value != row.action }
        for (chord, action) in KeymapDefaults.map where action == row.action { desired[chord] = action }
        row.showMessage(nil)
        persist()
    }

    private func resetAll() {
        desired = reservedEntries(of: KeymapDefaults.map)
        rows.forEach { $0.showMessage(nil) }
        persist()
    }

    /// Write the override set, reload the live config, then refresh every row from the new keymap.
    private func persist() {
        do {
            try ConfigWriter.apply(keybinds: desired)
        } catch {
            rows.first?.showMessage("Couldn't write config: \(error.localizedDescription)")
            return
        }
        AppConfig.reload()
        desired = reservedEntries(of: GeneralConfig.current.keymap)
        refreshRows()
    }

    private func refreshRows() {
        for row in rows {
            let shortcut = displayedChord(for: row.action)?.displayGlyph ?? ""
            row.render(currentShortcut: shortcut, isOverridden: isOverridden(row.action))
        }
    }

    // MARK: helpers

    private func reservedEntries(
        of map: [Chord: KeyInterceptor.ReservedChord]
    ) -> [Chord: KeyInterceptor.ReservedChord] {
        map.filter { if case .toggleToolFloat = $0.value { return false } else { return true } }
    }

    /// The chord shown for an action — the deterministic first of its `desired` chords by token.
    private func displayedChord(for action: KeyInterceptor.ReservedChord) -> Chord? {
        desired.filter { $0.value == action }.map(\.key).sorted { $0.configToken < $1.configToken }.first
    }

    /// True when the action's current chords differ from its built-in defaults.
    private func isOverridden(_ action: KeyInterceptor.ReservedChord) -> Bool {
        let current = Set(desired.filter { $0.value == action }.map(\.key))
        let defaults = Set(KeymapDefaults.map.filter { $0.value == action }.map(\.key))
        return current != defaults
    }

    private func moveRow(from row: KeybindRow, delta: Int) {
        guard let index = rows.firstIndex(where: { $0 === row }) else { return }
        guard let next = KeyboardFocus.step(from: index, delta: delta, count: rows.count) else { return }
        rows[next].window?.makeFirstResponder(rows[next].recordButton)
    }
}
```

Then update the call site in `Sources/ZenTerm/WindowController.swift` — `openSettings()` now passes the capturer into the section:

```swift
        sections: [SettingsKeybindsSection(capturer: keybindCapturer)],
```

- [ ] **Step 3: Verify build**

Run: `swift build && swift test`
Expected: build succeeds; all existing tests still green (this task adds no unit tests — the editor is GUI, verified by runbook).

- [ ] **Step 4: Manual runbook**

Run: `swift run ZenTerm`. Open Settings (`⌘,`). Tab/arrow to a Keybinds row (e.g. Toggle Zoom), press "Change", press `⌘⇧Z`. Expected: the keycap updates to `⌘⇧Z`; `⌘⇧Z` now toggles zoom immediately (no restart); `cat ~/.config/zen-term/config` shows `keybind = toggle_zoom=cmd+shift+z` with surrounding comments intact. Try binding `⌘P` onto a second action → inline "⌘P is already bound to Command Palette" and no change. Try a bare letter → "Needs at least one modifier." Press the row's reset (⤺) → keycap returns to `⌘F`, the `keybind =` line disappears. "Reset all to defaults" clears every override. Report observations (hand to Drew for GUI verification).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/SettingsKeybindsSection.swift Sources/ZenTerm/KeybindRow.swift Sources/ZenTerm/Controls/AppButton.swift Sources/ZenTerm/WindowController.swift
git commit -m "Add Keybinds editor: capture, block-on-conflict, live rebind, reset

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Docs + full gate + runbook

Document `open_settings` in the reference config (kept commented so it still parses to `.builtIn`), note in-app live editing, and run the full local gate + the complete runbook.

**Files:**
- Modify: `docs/config/config`
- Verify: `Tests/ZenTermTests/ReferenceConfigTests.swift` (unchanged — must stay green)

- [ ] **Step 1: Document the new action**

In `docs/config/config`, in the Actions list comment (after line 116, the `toggle_command_palette` group), add `open_settings` to the action set:

```
#   toggle_lazygit  toggle_repo_picker  toggle_command_palette  open_settings
```

In the defaults list (after line 140, `keybind = toggle_command_palette=cmd+p`), add the commented default:

```
# keybind = open_settings=cmd+,
```

Update the launch caveat (line 10-11) to note in-app live editing:

```
# bad lines are logged and skipped). Config is read once at launch — restart to
# apply hand-edits. Changes made in the in-app Settings card (⌘,) apply live.
```

- [ ] **Step 2: Verify the reference config still yields builtIn**

Run: `swift test --filter ReferenceConfigTests`
Expected: PASS — `test_referenceConfig_isAllCommented_yieldingBuiltIn` stays green (the new `open_settings` line is commented, and `KeymapDefaults.map` already carries `⌘, → openSettings`, so `.builtIn` is unchanged).

- [ ] **Step 3: Run the full local gate**

Run: `bin/check`
Expected: fully green — `swift build`, `swift test` (all suites), `swift format lint --strict`, `swiftlint --strict`. If the formatter/linter flags anything, run `bin/check --fix` and re-run `bin/check`.

- [ ] **Step 4: Full manual runbook**

Run: `swift run ZenTerm` and verify (hand to Drew — GUI verification needs a human):
- `⌘,` and `⌘P` → "Settings…" both open the card.
- Keyboard-only: Up/Down move the nav; Right/Tab enter the detail; the Keybinds rows scroll and focus; Esc closes.
- Rebind an action → works immediately, no restart; `config` shows the `keybind =` line with comments intact.
- Conflict → inline block naming the owner; modifier-less → inline "needs a modifier".
- Per-row reset removes the line and restores the default; Reset-all clears every override.
- **ZEN-43 regression:** ⌘P / ⌘⇧P / Add-Workspace / Settings all live-switch to each other; a tab-bar click while Settings is open dismisses it; the dock button lights only for the command palette; ⌘N is gated while Settings is open.
- **AddWorkspace regression:** the Add-Workspace form's keyboard nav still behaves exactly as before (it now routes through `KeyboardFocus`).

- [ ] **Step 5: Commit**

```bash
git add docs/config/config
git commit -m "Document open_settings + in-app live config editing (⌘,)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review notes (addressed)

- **Config is additive** — there's no "unbind to nothing" directive, so the editor offers rebind + reset only (no clear); documented in Task 8's model rules.
- **Float safety** — `applyKeybinds` preserves `keybind = toggle_float:…` lines and never touches `float =` lines (Task 3 tests cover both).
- **Reference-config invariant** — the doc's `open_settings` line stays commented; `KeymapDefaults.map` carries the `⌘,` default, so `.builtIn` (and `ReferenceConfigTests`) is unaffected (Task 9).
- **Behavior-preserving extraction** — `KeyboardFocus` moves the mechanics only; `AddWorkspaceOverlay`'s `verticalStops()`/anchor logic is unchanged (Task 5), re-verified in the Task 9 runbook.
- **Capture can't be pre-empted** — the global `KeyInterceptor` monitor sees keyDowns before the responder chain, so chord capture routes *through* a `KeybindCapturing` seam on the interceptor (Task 7), not a view-local key handler; the card ends capture on dismiss so no handler is left armed.
- **Type consistency** — `ConfigWriter.apply(scalars:removals:keybinds:configRoot:)`, `AppConfig.reload()`, `KeyboardFocus.step`/`isFocused`, `SettingsSection`/`SettingsOverlay`/`SettingsKeybindsSection`/`KeybindRow`/`SettingsNavRow`, and `Chord.configToken` names are used identically across tasks.
