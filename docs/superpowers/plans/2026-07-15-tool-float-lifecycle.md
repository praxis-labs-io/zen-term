# Tool Float Lifecycle (ZEN-77) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every user-defined tool float a configurable lifecycle via one `persist:` field, so a float can keep its process alive across close/reopen.

**Architecture:** Scope only exists when a float is persistent, so it's one field, not three: `persist: none | dir | tab`. `TabController` already owns `activeToolFloat` (what is **shown**); this adds `persistentFloats` (what is **alive**), making liveness and visibility independent — exactly how lazygit already models it. Dismiss drops the overlay and keeps the surface unless the float is ephemeral. A `dir:` field pins a float's working directory.

**Tech Stack:** Swift 6 / SwiftPM / AppKit. Tests: XCTest. Terminal surfaces come through the `TerminalSurface` seam in `TerminalKit`; tests use the `RecordingSurface` double.

**Spec:** `docs/superpowers/specs/2026-07-15-tool-float-lifecycle-design.md`

**Scope boundary:** This ticket is **PR 1 of 3**. `persist:window` is ZEN-141 and is deliberately NOT in the enum here — a documented-but-unimplemented value would be a lie, and `Persistence` is exhaustively switched so ZEN-141 adding a case is compile-enforced. Deleting the bespoke lazygit path is ZEN-140. **Do not touch lazygit in this PR** beyond the one shared rename in Task 3.

## Global Constraints

- **`bin/check` is the gate**, not `swift build` + `swift test`. It runs build → test → `swift format lint --strict` → `swiftlint --strict`, and CI enforces all four. `bin/check --fix` auto-applies format/lint fixes.
- **Formatting:** 4-space indent, 120-column line length (`.swift-format`), max 1 consecutive blank line.
- **Never hardcode a color.** Every color resolves from `Theme.current` — `Theme.current.chrome` roles, or `chrome.ink(alpha:)` for foreground-toned inks. Banned: `NSColor(white:)`, `.white`/`.black`, raw hex, and AppKit semantic colors (`.secondaryLabelColor`, `placeholderString`'s default tint, …).
- **Never block the main thread.** No synchronous subprocess, filesystem walk, or blocking I/O on the main queue.
- **No `TODO`/`FIXME`/`HACK`/`XXX` markers** and no `swiftlint:disable`. Fix it now or file a Linear ticket.
- **`Sources/ZenTerm/` must never `import GhosttyKit`** (enforced at the module level in `Package.swift`).
- **WHY comments only, never WHAT.** If code needs a "what" comment, rename instead.
- **AppKit controls get window-based interaction tests, not state-only tests.** A test that only asserts the backing view-model passes while the control is dead.
- No force-unwrap except documented AppKit (`contentView!`).

---

### Task 1: Delete `EmptyGuard`

Pure deletion, no behavior change. `EmptyGuard` exists on the type and is honored at runtime, but `ToolFloatParser` hardcodes `emptyGuard: nil` (line 63) — no config can author one. It was built for a diff float that shipped as `gitdash` instead. Deleting it removes a whole async path (background probe + 2s watchdog) before we add the lifecycle engine on top.

**Files:**
- Modify: `Sources/ZenTerm/ToolFloat.swift` — remove the `emptyGuard` property and the `EmptyGuard` struct
- Modify: `Sources/ZenTerm/ToolFloatParser.swift:63` — drop `emptyGuard: nil`
- Modify: `Sources/ZenTerm/TabController.swift` — `toggleToolFloat`, `probeIsEmpty`, `probingToolFloatID`, `probeTimeout`
- Modify: `Sources/ZenTerm/ConfigWriter.swift` — the `emptyGuard` sentence in `serializeFloat`'s doc comment
- Modify: `Sources/ZenTerm/ToolFloatFormOverlay.swift:485` — drop `emptyGuard: editingFloat?.emptyGuard`

**Interfaces:**
- Consumes: nothing.
- Produces: `ToolFloat` without `emptyGuard`; `TabController.toggleToolFloat(_:)` becomes fully synchronous.

- [ ] **Step 1: Remove `emptyGuard` from `ToolFloat` and delete the `EmptyGuard` struct**

In `Sources/ZenTerm/ToolFloat.swift`, delete the `let emptyGuard: EmptyGuard?` line from the struct, and delete the entire `EmptyGuard` struct together with its doc comment (the `/// A pre-open probe: …` block). The file should end with `ToolFloat` and `ToolFloatCatalog` only.

- [ ] **Step 2: Drop `emptyGuard: nil` from the parser**

In `Sources/ZenTerm/ToolFloatParser.swift`, remove the `emptyGuard: nil,` line from the `ToolFloat(...)` construction in `parse(_:)`.

- [ ] **Step 3: Collapse `toggleToolFloat` to the synchronous path**

Replace `TabController.toggleToolFloat(_:)` (currently ~line 739) with:

```swift
/// Toggle a tool float: same id open → close; otherwise run the git guard and open.
func toggleToolFloat(_ spec: ToolFloat) {
    if activeToolFloat?.spec.id == spec.id { closeToolFloat(); return }
    if activeToolFloat != nil { closeToolFloat() }  // switch floats
    if spec.requiresGitRepo, gitRepoRoot(for: focusedCWD) == nil {
        onRequestToast?(
            ToastContent(
                variant: .info,
                title: spec.title,
                message: "This needs a Git repository. Run `git init` here, "
                    + "or open a folder that has one."))
        return
    }
    showToolFloat(spec)
}
```

- [ ] **Step 4: Delete the probe machinery**

In `Sources/ZenTerm/TabController.swift`, delete:
- the `probingToolFloatID` property and its doc comment (in the block near line 100)
- `private static let probeTimeout: TimeInterval = 2` and its doc comment
- the entire `probeIsEmpty(_:completion:)` function and its doc comment (through the closing brace before `// MARK: tiling`)

- [ ] **Step 5: Drop `emptyGuard` from the Settings form**

In `Sources/ZenTerm/ToolFloatFormOverlay.swift`, remove the `emptyGuard: editingFloat?.emptyGuard,` line from `buildFloat()`'s `ToolFloat(...)` construction.

- [ ] **Step 6: Fix the `ConfigWriter` doc comment**

In `Sources/ZenTerm/ConfigWriter.swift`, delete this sentence from `serializeFloat`'s doc comment — it describes a type that no longer exists:

```
/// yet (the parser always reads it as nil), so it isn't serialized.
```

Remove the whole trailing clause starting at "`emptyGuard` has no grammar yet". The comment should end after the `WorkspacesWriter` quoting sentence.

- [ ] **Step 7: Drop `emptyGuard: nil` from the test constructions**

No test *asserts* `emptyGuard`, but four test files pass it positionally when constructing a `ToolFloat`, so they won't compile until it's removed. Delete the `emptyGuard: nil,` argument from each:

- `Tests/ZenTermTests/ToggleDockTests.swift:13`
- `Tests/ZenTermTests/ToolFloatFormOverlayTests.swift:226` and `:246`
- `Tests/ZenTermTests/ConfigWriterTests.swift:160`
- `Tests/ZenTermTests/KeymapAssemblyTests.swift:10`

No assertion changes — the argument was always `nil`.

- [ ] **Step 8: Run the gate**

Run: `bin/check`
Expected: green.

Then confirm the deletion is total:

```bash
grep -rn "emptyGuard\|EmptyGuard" Sources/ Tests/
```

Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
ZEN-77: delete EmptyGuard

Dead capability: the type existed and toggleToolFloat honored it, but
ToolFloatParser hardcoded emptyGuard: nil, so no config could author one. It was
built for a diff float that shipped as gitdash instead.

Removes the background probe and its 2s watchdog, making toggleToolFloat fully
synchronous before the persistence engine lands on top.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DV9pfKR82fdTLWSwQREbdi
EOF
)"
```

---

### Task 2: `Persistence` enum + `persist:` config grammar

Add the field and its round-trip. No behavior yet — the engine still spawns/terminates every open. A reviewer can accept this config surface and separately judge the engine in Task 3.

**Files:**
- Modify: `Sources/ZenTerm/ToolFloat.swift` — add `Persistence` + the `persist` property
- Modify: `Sources/ZenTerm/ToolFloatParser.swift` — parse `persist:`
- Modify: `Sources/ZenTerm/ConfigWriter.swift` — serialize `persist:`
- Modify: `Sources/ZenTerm/ToolFloatFormOverlay.swift:477` — pass `persist:` through (preserve on edit)
- Modify: `docs/config/config` — document the field
- Test: `Tests/ZenTermTests/ToolFloatParserTests.swift`, `Tests/ZenTermTests/ConfigWriterTests.swift`

**Interfaces:**
- Consumes: `ToolFloat` without `emptyGuard` (Task 1).
- Produces:
  - `ToolFloat.Persistence` — `enum Persistence: String { case ephemeral = "none", directory = "dir", tab = "tab" }`
  - `ToolFloat.persist: Persistence` — a stored property, positioned after `requiresGitRepo` and before `toggle`.
  - `ToolFloatParser.defaultPersist: ToolFloat.Persistence` = `.ephemeral`

> **Naming:** the case is `ephemeral`, not `none`. A `case none` on a type used as `Persistence?` collides with `Optional.none` and produces Swift's "assuming you mean" ambiguity. The raw value carries the config token, so `persist:none` still parses. Same reason `directory` is the case name for `dir`.

- [ ] **Step 1: Write the failing parser tests**

Add to `Tests/ZenTermTests/ToolFloatParserTests.swift`:

```swift
func test_persist_defaultsToEphemeral() {
    let float = ToolFloatParser.parse("id:x command:c key:cmd+shift+j")
    XCTAssertEqual(float?.persist, .ephemeral)
}

func test_persist_parsesEveryToken() {
    XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:none")?.persist, .ephemeral)
    XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:dir")?.persist, .directory)
    XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:tab")?.persist, .tab)
}

func test_persist_caseInsensitive() {
    XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:DIR")?.persist, .directory)
}

/// An unknown value must not drop the whole float — the float still works, just ephemerally.
func test_persist_unknownValue_fallsBackToEphemeral() {
    let float = ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:banana")
    XCTAssertEqual(float?.persist, .ephemeral)
    XCTAssertEqual(float?.id, "x")
}

/// `window` is ZEN-141. Until then it must degrade, not silently look supported.
func test_persist_window_isNotYetSupported() {
    XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:window")?.persist, .ephemeral)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ToolFloatParserTests`
Expected: FAIL — `value of type 'ToolFloat' has no member 'persist'`.

- [ ] **Step 3: Add `Persistence` and the `persist` property**

In `Sources/ZenTerm/ToolFloat.swift`, add the property to `ToolFloat` after `requiresGitRepo`:

```swift
    let requiresGitRepo: Bool
    let persist: Persistence
    let toggle: Chord  // the config `key:` — binds the chord AND renders the palette glyph
```

And add the nested enum inside `ToolFloat`, above `shortcut`:

```swift
    /// How long a float's process lives, and where the live instance is kept. Scope only exists
    /// when a float persists — an ephemeral tool spawns fresh at the focused cwd every open, so it
    /// has no instance to scope. The raw value is the config token; the case names avoid colliding
    /// with `Optional.none` (`.none`) and with the `dir:` field.
    enum Persistence: String {
        /// Terminate on dismiss; fresh spawn every open. Right for anything whose state goes stale
        /// (a file explorer, a scratch shell).
        case ephemeral = "none"
        /// One live instance per directory identity, per tab — reopening in the same directory
        /// restores it; a different one discards and respawns. Right for directory-bound tools.
        case directory = "dir"
        /// One live instance per tab, anchored at first-open cwd. Never re-anchors.
        case tab
    }
```

- [ ] **Step 4: Parse `persist:`**

In `Sources/ZenTerm/ToolFloatParser.swift`, add the default next to the others:

```swift
    static let defaultPersist: ToolFloat.Persistence = .ephemeral
```

Add `persist:` to the `ToolFloat(...)` construction in `parse(_:)`, after `requiresGitRepo:`:

```swift
            requiresGitRepo: fields["git"]?.lowercased() == "true",
            persist: persistence(fields["persist"], id: id),
            toggle: toggle)
```

And add the helper next to `fraction(_:)`:

```swift
    /// A float's `persist:` value. An unrecognized token warns and falls back to the default rather
    /// than dropping the float — an ephemeral float still works, so a typo shouldn't cost the tool.
    private static func persistence(_ raw: String?, id: String) -> ToolFloat.Persistence {
        guard let raw else { return defaultPersist }
        guard let value = ToolFloat.Persistence(rawValue: raw.lowercased()) else {
            NSLog("GeneralConfig: float `\(id)` has unknown `persist:\(raw)` — using `none`")
            return defaultPersist
        }
        return value
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ToolFloatParserTests`
Expected: FAIL to compile — `ToolFloatFormOverlay.buildFloat()` and any other `ToolFloat(...)` construction now miss the `persist:` argument. Fix `Sources/ZenTerm/ToolFloatFormOverlay.swift`'s `buildFloat()` by preserving the editing float's value (the form control lands in Task 5):

```swift
            requiresGitRepo: gitSegment.selectedIndex == 1,
            persist: editingFloat?.persist ?? ToolFloatParser.defaultPersist,
            toggle: chord)
```

Re-run. Expected: PASS.

- [ ] **Step 6: Write the failing writer test**

Add to `Tests/ZenTermTests/ConfigWriterTests.swift`:

```swift
func test_serializeFloat_omitsDefaultPersist_andEmitsNonDefault() {
    let lean = ToolFloat(
        id: "dev", title: "Open dev", icon: ToolFloatParser.defaultIcon, command: "vim",
        widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
        persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "d"))
    XCTAssertEqual(ConfigWriter.serializeFloat(lean), "float = id:dev key:cmd+shift+d command:vim")

    let sticky = ToolFloat(
        id: "dev", title: "Open dev", icon: ToolFloatParser.defaultIcon, command: "vim",
        widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
        persist: .directory, toggle: Chord(command: true, shift: true, key: "d"))
    XCTAssertEqual(
        ConfigWriter.serializeFloat(sticky), "float = id:dev key:cmd+shift+d command:vim persist:dir")
}

func test_serializeFloat_persistRoundTripsThroughParser() {
    let original = ToolFloat(
        id: "lg", title: "Open Lazygit", icon: "git", command: "lazygit",
        widthFraction: 0.85, heightFraction: 0.78, requiresGitRepo: true,
        persist: .directory, toggle: Chord(command: true, key: "g"))
    let line = ConfigWriter.serializeFloat(original)
    XCTAssertEqual(ToolFloatParser.parse(String(line.dropFirst("float = ".count))), original)
}
```

- [ ] **Step 7: Run test to verify it fails**

Run: `swift test --filter ConfigWriterTests`
Expected: FAIL — the serialized line has no `persist:dir` token.

- [ ] **Step 8: Serialize `persist:`**

In `Sources/ZenTerm/ConfigWriter.swift`, in `serializeFloat`, add after the `git:true` line and before the `return`:

```swift
        if float.requiresGitRepo { tokens.append("git:true") }
        if float.persist != ToolFloatParser.defaultPersist { tokens.append("persist:\(float.persist.rawValue)") }
        return "float = " + tokens.joined(separator: " ")
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `swift test --filter ConfigWriterTests`
Expected: PASS.

> Four test files construct `ToolFloat(...)` directly and will fail to compile until each gains `persist:` — `ToggleDockTests.swift`, `ToolFloatFormOverlayTests.swift` (two sites), `ConfigWriterTests.swift`, `KeymapAssemblyTests.swift`. Add `persist: .ephemeral` to every one; it's the default, so no existing assertion changes. Find them all with `grep -rn "ToolFloat(" Tests/`.

- [ ] **Step 10: Document the field**

In `docs/config/config`, in the "Tool floats" block, add to the field list after the `git` line:

```
#   persist  (optional)  process lifetime                             (default none)
#                        none = terminate on dismiss, fresh every open
#                        dir  = keep alive per directory (repo root if in a repo, else
#                               the cwd); reopening elsewhere respawns
#                        tab  = keep alive per tab, anchored at first open
```

And add an example after the dev-server one:

```
# Example — a git TUI kept warm per repo (first open is cold; reopens are instant):
# float = id:lazygit command:"lazygit" key:cmd+g git:true persist:dir icon:git title:"Open Lazygit"
```

- [ ] **Step 11: Run the gate**

Run: `bin/check`
Expected: green.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
ZEN-77: add the persist: config field

Adds ToolFloat.Persistence (none|dir|tab) and its parser/writer round-trip. No
behavior yet — the engine still terminates on dismiss; this is the config surface
only.

The case names are ephemeral/directory/tab rather than none/dir/tab: a `case none`
on a type used as Persistence? collides with Optional.none. Raw values carry the
config tokens.

persist:window is ZEN-141 and is deliberately absent — the enum is exhaustively
switched, so adding it later is compile-enforced.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DV9pfKR82fdTLWSwQREbdi
EOF
)"
```

---

### Task 3: The persistence engine

The meat. `activeToolFloat` keeps meaning "what is shown"; `persistentFloats` becomes "what is alive".

**Files:**
- Modify: `Sources/ZenTerm/TabController.swift` — the registry, `showToolFloat`, `closeToolFloat`, `surfaceDidExit`, `shutdown`, `allSurfaces`, rename `lazygitAnchor` → `directoryAnchor`
- Modify: `Tests/ZenTermTests/RecordingSurface.swift` — make `currentDirectory` settable
- Create: `Tests/ZenTermTests/TabControllerToolFloatTests.swift`

**Interfaces:**
- Consumes: `ToolFloat.persist` (Task 2); `RecordingSurface.terminated` / `.startCount` (existing).
- Produces:
  - `TabController.persistentFloats: [String: (surface: TerminalSurface, anchor: URL?)]` (private)
  - `TabController.directoryAnchor(for:) -> URL?` (private) — renamed from `lazygitAnchor`, same body, now shared by lazygit and `persist:dir`
  - `RecordingSurface.currentDirectory: URL?` — a settable stored property overriding the protocol extension's `nil` default

> **Why the rename is in scope, not adjacent refactoring:** `lazygitAnchor` *is* the directory-identity function `persist:dir` needs, character for character. Duplicating it would be worse, and ZEN-140 deletes the lazygit call sites anyway.

- [ ] **Step 1: Make `RecordingSurface.currentDirectory` settable**

`TerminalSurface.currentDirectory` has a `nil` default in a protocol extension, so `RecordingSurface` currently reports nil and `focusedCWD` falls back to `cwdByLeaf`. A stored property lets a test drive real cwd drift through the same path production uses.

In `Tests/ZenTermTests/RecordingSurface.swift`, add after `var lastConfig: TerminalSurfaceConfig?`:

```swift
    /// Overrides the protocol extension's nil default so a test can drive cwd drift — the same
    /// property `PaneCanvasController.focusedCWD` prefers over its last OSC-reported value.
    var currentDirectory: URL?
```

- [ ] **Step 2: Write the failing engine tests**

Create `Tests/ZenTermTests/TabControllerToolFloatTests.swift`:

```swift
import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Lifecycle tests for the tool-float engine (ZEN-77): drive `toggleToolFloat` on a window-mounted
/// controller and assert what the `persist:` mode does to the underlying surface. Asserts through
/// the real spawn/terminate path (`RecordingSurface.startCount` / `.terminated`) rather than the
/// registry, because a state-only test would pass while the surface was actually being killed.
final class TabControllerToolFloatTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var controllers: [TabController] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-floats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        controllers.forEach { $0.shutdown() }
        controllers = []
        windows = []
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: harness

    private func makeDir(_ name: String, git: Bool) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if git {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        }
        return dir
    }

    /// A window-mounted controller over `cwd`, recording every surface it spawns. Left unpinned so
    /// the lazygit pre-warm path (gated on `pinnedTitle != nil`) never fires and pollutes `spawned`.
    private func makeController(cwd: URL) -> (controller: TabController, spawned: () -> [RecordingSurface]) {
        var spawned: [RecordingSurface] = []
        let controller = TabController(
            initialCWD: cwd,
            makeSurface: {
                let surface = RecordingSurface()
                spawned.append(surface)
                return surface
            },
            prewarmPool: LazygitPrewarmPool(capacity: 3), prewarmDelay: 0)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        windows.append(window)
        controllers.append(controller)
        return (controller, { spawned })
    }

    private func spec(_ id: String, persist: ToolFloat.Persistence, git: Bool = false) -> ToolFloat {
        ToolFloat(
            id: id, title: "Open \(id)", icon: ToolFloatParser.defaultIcon, command: id,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: git,
            persist: persist, toggle: Chord(command: true, shift: true, key: "j"))
    }

    /// The float surfaces only — filtered by the command the spec launches, so the tab's own pane
    /// surface never counts.
    private func floatSurfaces(_ spawned: [RecordingSurface], command: String) -> [RecordingSurface] {
        spawned.filter { $0.lastConfig?.args == ["-l", "-i", "-c", command] }
    }

    /// The tab's initial pane surface — the one `focusedCWD` reads `currentDirectory` from.
    private func paneSurface(_ spawned: [RecordingSurface]) -> RecordingSurface { spawned[0] }

    // MARK: tests

    func test_ephemeralFloat_terminatesOnDismiss() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)
        let float = spec("yazi", persist: .ephemeral)

        controller.toggleToolFloat(float)
        let opened = floatSurfaces(spawned(), command: "yazi")
        XCTAssertEqual(opened.count, 1)

        controller.closeToolFloat()
        XCTAssertTrue(opened[0].terminated, "an ephemeral float must die on dismiss")

        controller.toggleToolFloat(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "yazi").count, 2, "reopen spawns fresh")
    }

    func test_dirFloat_survivesDismiss_andReusesSurfaceOnReopen() throws {
        let repo = try makeDir("repo", git: true)
        let (controller, spawned) = makeController(cwd: repo)
        let float = spec("lazygit", persist: .directory)

        controller.toggleToolFloat(float)
        let first = floatSurfaces(spawned(), command: "lazygit")
        XCTAssertEqual(first.count, 1)

        controller.closeToolFloat()
        XCTAssertFalse(first[0].terminated, "a persistent float must survive dismiss")

        controller.toggleToolFloat(float)
        XCTAssertEqual(
            floatSurfaces(spawned(), command: "lazygit").count, 1, "reopen must reuse, not respawn")
        XCTAssertEqual(first[0].startCount, 1, "the retained surface must not be restarted")
    }

    func test_dirFloat_respawnsWhenAnchorChanges() throws {
        let repoA = try makeDir("a", git: true)
        let repoB = try makeDir("b", git: true)
        let (controller, spawned) = makeController(cwd: repoA)
        let float = spec("lazygit", persist: .directory)

        controller.toggleToolFloat(float)
        let first = floatSurfaces(spawned(), command: "lazygit")[0]
        controller.closeToolFloat()

        paneSurface(spawned()).currentDirectory = repoB  // the focused pane cd'd to another repo
        controller.toggleToolFloat(float)

        XCTAssertTrue(first.terminated, "the stale instance must be discarded")
        let all = floatSurfaces(spawned(), command: "lazygit")
        XCTAssertEqual(all.count, 2, "a new repo gets a new instance")
        XCTAssertEqual(all[1].lastConfig?.workingDirectory, repoB)
    }

    func test_dirFloat_anchorsToRepoRoot_soSubdirReusesTheInstance() throws {
        let repo = try makeDir("repo", git: true)
        let sub = repo.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let (controller, spawned) = makeController(cwd: repo)
        let float = spec("lazygit", persist: .directory)

        controller.toggleToolFloat(float)
        controller.closeToolFloat()
        paneSurface(spawned()).currentDirectory = sub  // same repo, different subdir
        controller.toggleToolFloat(float)

        XCTAssertEqual(
            floatSurfaces(spawned(), command: "lazygit").count, 1,
            "cd'ing within one repo must not reload the float")
    }

    func test_dirFloat_outsideARepo_anchorsToThePlainCWD() throws {
        let dirA = try makeDir("plain-a", git: false)
        let dirB = try makeDir("plain-b", git: false)
        let (controller, spawned) = makeController(cwd: dirA)
        let float = spec("btm", persist: .directory)

        controller.toggleToolFloat(float)
        controller.closeToolFloat()
        controller.toggleToolFloat(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "btm").count, 1, "same dir reuses")

        controller.closeToolFloat()
        paneSurface(spawned()).currentDirectory = dirB
        controller.toggleToolFloat(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "btm").count, 2, "a different dir respawns")
    }

    func test_tabFloat_doesNotRespawnWhenCWDChanges() throws {
        let repoA = try makeDir("a", git: true)
        let repoB = try makeDir("b", git: true)
        let (controller, spawned) = makeController(cwd: repoA)
        let float = spec("btop", persist: .tab)

        controller.toggleToolFloat(float)
        let first = floatSurfaces(spawned(), command: "btop")[0]
        controller.closeToolFloat()

        paneSurface(spawned()).currentDirectory = repoB
        controller.toggleToolFloat(float)

        XCTAssertFalse(first.terminated, "a tab float must not re-anchor")
        XCTAssertEqual(floatSurfaces(spawned(), command: "btop").count, 1)
    }

    func test_persistentFloat_terminatedOnShutdown() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)

        controller.toggleToolFloat(spec("btop", persist: .tab))
        let surface = floatSurfaces(spawned(), command: "btop")[0]
        controller.closeToolFloat()
        XCTAssertFalse(surface.terminated)

        controller.shutdown()
        XCTAssertTrue(surface.terminated, "a hidden persistent float must not outlive its tab")
    }

    func test_persistentFloat_processExit_clearsRegistry_soNextOpenSpawnsFresh() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)
        let float = spec("lazygit", persist: .tab)

        controller.toggleToolFloat(float)
        let first = floatSurfaces(spawned(), command: "lazygit")[0]
        controller.surfaceDidExit(first, code: 0)  // `q` inside the tool

        controller.toggleToolFloat(float)
        XCTAssertEqual(
            floatSurfaces(spawned(), command: "lazygit").count, 2,
            "a quit tool must spawn fresh on the next open, not resurrect a dead surface")
    }

    func test_hiddenPersistentFloat_processExit_clearsRegistry() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)
        let float = spec("lazygit", persist: .tab)

        controller.toggleToolFloat(float)
        let first = floatSurfaces(spawned(), command: "lazygit")[0]
        controller.closeToolFloat()
        controller.surfaceDidExit(first, code: 0)  // the tool died while hidden

        controller.toggleToolFloat(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "lazygit").count, 2)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter TabControllerToolFloatTests`
Expected: FAIL. `test_ephemeralFloat_terminatesOnDismiss` passes (today's behavior), the rest fail — persistent floats are terminated on dismiss and respawned on reopen.

- [ ] **Step 4: Add the registry and the dismissing-overlay slot**

In `Sources/ZenTerm/TabController.swift`, replace the `activeToolFloat` doc comment and add the new state below it:

```swift
    /// The tool float currently SHOWN. Floats are modal and mutually exclusive, so one slot
    /// suffices. Whether its surface dies on dismiss depends on `spec.persist`.
    private var activeToolFloat: (spec: ToolFloat, surface: TerminalSurface, overlay: SurfaceFloatOverlay)?
    var isToolFloatOpen: Bool { activeToolFloat != nil }
    var activeToolFloatID: String? { activeToolFloat?.spec.id }

    /// Tool floats whose process is ALIVE, keyed by float id — the persistent ones, kept across
    /// dismissal. Liveness and visibility are independent: a float can be in here while hidden.
    /// `anchor` is the directory identity a `.directory` float was launched against; nil for `.tab`
    /// (which never re-anchors) and for floats that aren't in here at all (`.ephemeral`).
    private var persistentFloats: [String: (surface: TerminalSurface, anchor: URL?)] = [:]

    /// A float overlay still springing out. It keeps Auto Layout constraints on a persistent
    /// float's shared `surface.view`, so a fast re-show must snap it away before re-hosting that
    /// view in a new card — otherwise the old constraints fight the new ones.
    private var dismissingFloatOverlay: SurfaceFloatOverlay?
```

- [ ] **Step 5: Rename `lazygitAnchor` to `directoryAnchor`**

In `Sources/ZenTerm/TabController.swift`, rename the function and generalize its doc comment:

```swift
    /// The directory identity a float is scoped to for `cwd`: the enclosing repo root (so cd'ing
    /// between a repo's own subdirs doesn't reload), else the plain cwd. Deliberately defined
    /// outside a repo too — a `persist:dir` float need not be a git tool.
    private func directoryAnchor(for cwd: URL?) -> URL? {
        gitRepoRoot(for: cwd) ?? cwd?.standardizedFileURL
    }
```

Update its two existing call sites (in `toggleLazygit` and `ensureLazygitSurface`) from `lazygitAnchor(for:` to `directoryAnchor(for:`. Do not change anything else about lazygit.

- [ ] **Step 6: Split `showToolFloat` into surface resolution + presentation**

Replace `showToolFloat(_:)` in `Sources/ZenTerm/TabController.swift` with:

```swift
    /// Present `spec` in a float card: resolve its surface (retained or fresh), host it, and give
    /// it the tab's unified focus. When the tool exits, `surfaceDidExit` tears the float down.
    private func showToolFloat(_ spec: ToolFloat) {
        // A still-springing-out card holds constraints on a persistent float's shared view — snap
        // it away before re-hosting that view.
        dismissingFloatOverlay?.removeFromSuperview()
        dismissingFloatOverlay = nil
        let surface = surfaceForFloat(spec)
        let overlay = SurfaceFloatOverlay(
            content: surface.view,
            background: Theme.current.chrome.background.nsColor,
            widthFraction: spec.widthFraction,
            heightFraction: spec.heightFraction,
            contentInset: 10,
            cornerRadius: 14,
            onDismiss: { [weak self] in self?.closeToolFloat() })
        presentTileOverlay(overlay)
        activeToolFloat = (spec, surface, overlay)
        paneCanvas.setPanesFocused(false)
        bottomDrawerPanel?.isFocused = false
        rightDrawerPanel?.isFocused = false
        surface.focus()
        overlay.animateIn()
        onOverlayStateChanged?()
    }

    /// The surface to show for `spec`: a retained one when the float persists and still matches its
    /// anchor, else a fresh spawn (discarding a drifted instance first). Registers persistent
    /// floats so a later dismissal keeps them alive.
    private func surfaceForFloat(_ spec: ToolFloat) -> TerminalSurface {
        let anchor = spec.persist == .directory ? directoryAnchor(for: focusedCWD) : nil
        if let live = persistentFloats[spec.id] {
            if spec.persist != .directory || live.anchor?.path == anchor?.path { return live.surface }
            discardPersistentFloat(spec.id)  // the focused dir moved to another repo → reload
        }
        let surface = spawnFloatSurface(spec)
        if spec.persist != .ephemeral { persistentFloats[spec.id] = (surface, anchor) }
        return surface
    }

    /// Spawn `spec.command` in a fresh login+interactive shell at the focused cwd, so the user's
    /// PATH and pager match a pane's.
    private func spawnFloatSurface(_ spec: ToolFloat) -> TerminalSurface {
        let surface = makeSurface()
        surface.delegate = self
        surface.start(
            TerminalSurfaceConfig(
                command: ShellLaunch.userShell, args: ["-l", "-i", "-c", spec.command],
                workingDirectory: focusedCWD, theme: Theme.current.terminal,
                behavior: GeneralConfig.current.terminalBehavior))
        return surface
    }

    /// Drop a persistent float's surface. Clears the ref BEFORE terminate so a synchronous
    /// `surfaceDidExit` re-entry can't resurrect the entry this is removing.
    private func discardPersistentFloat(_ id: String) {
        guard let live = persistentFloats.removeValue(forKey: id) else { return }
        live.surface.terminate()
    }
```

- [ ] **Step 7: Make `closeToolFloat` respect `persist`**

Replace `closeToolFloat()` with:

```swift
    /// Close the float. An ephemeral float's surface dies with the card; a persistent one keeps
    /// running and only loses its card. Clears the slot before terminate so a synchronous
    /// `surfaceDidExit` re-entry no-ops.
    func closeToolFloat() {
        guard let active = activeToolFloat else { return }
        activeToolFloat = nil
        let overlay = active.overlay
        overlay.animateOut { [weak self] in
            overlay.removeFromSuperview()
            if self?.dismissingFloatOverlay === overlay { self?.dismissingFloatOverlay = nil }
        }
        if active.spec.persist == .ephemeral {
            active.surface.terminate()
        } else {
            dismissingFloatOverlay = overlay
        }
        restoreUnifiedFocus()
        onOverlayStateChanged?()
    }
```

- [ ] **Step 8: Handle a float's process exiting**

In `surfaceDidExit(_:code:)`, replace the tool-float branch with:

```swift
        if let active = activeToolFloat, s === active.surface {
            // The tool ran to completion / quit (`q` in lazygit) → close the float and forget it,
            // so the next open spawns fresh rather than resurrecting a dead surface.
            activeToolFloat = nil
            persistentFloats.removeValue(forKey: active.spec.id)
            active.overlay.animateOut { active.overlay.removeFromSuperview() }
            active.surface.terminate()
            restoreUnifiedFocus()
            onOverlayStateChanged?()
            return
        }
        if let id = persistentFloats.first(where: { $0.value.surface === s })?.key {
            persistentFloats.removeValue(forKey: id)  // a hidden persistent float's tool quit
            s.terminate()
            return
        }
```

- [ ] **Step 9: Terminate persistent floats on shutdown, and re-theme them**

In `shutdown()`, replace the three `activeToolFloat` lines with:

```swift
        activeToolFloat?.overlay.removeFromSuperview()
        activeToolFloat?.surface.terminate()
        activeToolFloat = nil
        dismissingFloatOverlay?.removeFromSuperview()
        dismissingFloatOverlay = nil
        for id in persistentFloats.keys { discardPersistentFloat(id) }
```

In `allSurfaces`, include the persistent floats so a live config change re-themes a hidden one:

```swift
    var allSurfaces: [TerminalSurface] {
        var result = paneCanvas.allSurfaces
        result.append(
            contentsOf: [bottomDrawerSurface, rightDrawerSurface, lazygitSurface, activeToolFloat?.surface]
                .compactMap { $0 })
        result.append(contentsOf: persistentFloats.values.map(\.surface))
        return result
    }
```

> `activeToolFloat?.surface` and a persistent float's surface are the same object while shown. That's fine — `allSurfaces` feeds an idempotent re-theme pass, and de-duplicating identity here would cost more than it saves.

- [ ] **Step 10: Run tests to verify they pass**

Run: `swift test --filter TabControllerToolFloatTests`
Expected: PASS, all 9.

- [ ] **Step 11: Run the gate**

Run: `bin/check`
Expected: green. `TabControllerLazygitTests` must still pass untouched — the rename is the only lazygit-adjacent change.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
ZEN-77: the tool-float persistence engine

activeToolFloat keeps meaning "what is shown"; persistentFloats is now "what is
alive". Dismiss drops the card and keeps the surface unless the float is
ephemeral, so liveness and visibility are independent.

persist:dir re-anchors on directory identity (repo root if inside a repo, else the
plain cwd), so cd'ing within a repo reuses the instance and moving to another repo
reloads it. persist:tab never re-anchors.

Renames lazygitAnchor -> directoryAnchor: it is character-for-character the
function persist:dir needs, and ZEN-140 removes the lazygit call sites anyway.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DV9pfKR82fdTLWSwQREbdi
EOF
)"
```

---

### Task 4: The `dir:` field

Pins a float's working directory. Without it, a cwd-independent tool (btop, a music player) spawns at whatever directory the focused pane happened to be in on first open.

**Files:**
- Modify: `Sources/ZenTerm/ToolFloat.swift` — add `dir: URL?`
- Modify: `Sources/ZenTerm/ToolFloatParser.swift` — parse `dir:`, warn on the degenerate combination
- Modify: `Sources/ZenTerm/ConfigWriter.swift` — serialize `dir:`
- Modify: `Sources/ZenTerm/TabController.swift` — `spawnFloatSurface` + `surfaceForFloat` honor it
- Modify: `docs/config/config`
- Test: `Tests/ZenTermTests/ToolFloatParserTests.swift`, `Tests/ZenTermTests/TabControllerToolFloatTests.swift`

**Interfaces:**
- Consumes: `ToolFloat.persist` (Task 2); `TabController.spawnFloatSurface` / `surfaceForFloat` (Task 3).
- Produces: `ToolFloat.dir: URL?` — stored property, positioned after `command`. `TabController.floatCWD(_:) -> URL?` (private).

- [ ] **Step 1: Write the failing parser tests**

Add to `Tests/ZenTermTests/ToolFloatParserTests.swift`:

```swift
func test_dir_defaultsToNil() {
    XCTAssertNil(ToolFloatParser.parse("id:x command:c key:cmd+shift+j")?.dir)
}

func test_dir_expandsTilde() {
    let float = ToolFloatParser.parse("id:x command:c key:cmd+shift+j dir:~/notes")
    XCTAssertEqual(float?.dir?.path, NSString(string: "~/notes").expandingTildeInPath)
}

func test_dir_quotedPathWithSpaces() {
    let float = ToolFloatParser.parse("id:x command:c key:cmd+shift+j dir:\"/tmp/my notes\"")
    XCTAssertEqual(float?.dir?.path, "/tmp/my notes")
}

/// A pinned dir has a fixed identity, so `persist:dir` can never re-anchor — it degenerates into
/// exactly `persist:tab`. Warn and keep the float rather than guessing.
func test_dirWithPersistDir_isDegenerate_butKeepsTheFloat() {
    let float = ToolFloatParser.parse("id:x command:c key:cmd+shift+j dir:/tmp persist:dir")
    XCTAssertEqual(float?.persist, .directory)
    XCTAssertEqual(float?.dir?.path, "/tmp")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ToolFloatParserTests`
Expected: FAIL — `value of type 'ToolFloat' has no member 'dir'`.

- [ ] **Step 3: Add the `dir` property**

In `Sources/ZenTerm/ToolFloat.swift`, add after `command`:

```swift
    let command: String  // runs as `$SHELL -l -i -c command` at the focused pane's cwd
    /// A pinned working directory, or nil to follow the focused pane's cwd. For a tool that isn't
    /// about the directory you're in (a music player, an email client) or one that means a specific
    /// one (a notes scratchpad).
    let dir: URL?
```

- [ ] **Step 4: Parse `dir:`**

In `Sources/ZenTerm/ToolFloatParser.swift`, add to the `ToolFloat(...)` construction after `command:`:

```swift
            command: command,
            dir: directory(fields["dir"], persist: persist, id: id),
```

This needs `persist` resolved first, so restructure `parse(_:)`'s tail — replace the whole `return ToolFloat(...)` with:

```swift
        let persist = persistence(fields["persist"], id: id)
        return ToolFloat(
            id: id,
            title: fields["title"] ?? Self.defaultTitle(forID: id),
            icon: fields["icon"] ?? Self.defaultIcon,
            command: command,
            dir: directory(fields["dir"], persist: persist, id: id),
            widthFraction: fraction(fields["width"]) ?? Self.defaultFraction,
            heightFraction: fraction(fields["height"]) ?? Self.defaultFraction,
            requiresGitRepo: fields["git"]?.lowercased() == "true",
            persist: persist,
            toggle: toggle)
```

Add the helper next to `persistence(_:id:)`:

```swift
    /// A float's pinned `dir:`, tilde-expanded. `dir:` + `persist:dir` is degenerate — a fixed
    /// directory has a fixed identity, so the re-anchor can never fire and the float behaves
    /// exactly like `persist:tab`. Warn rather than silently reinterpret the author's intent.
    private static func directory(_ raw: String?, persist: ToolFloat.Persistence, id: String) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if persist == .directory {
            NSLog(
                "GeneralConfig: float `\(id)` sets both `dir:` and `persist:dir` — a pinned directory "
                    + "never re-anchors, so this behaves as `persist:tab`")
        }
        return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath).standardizedFileURL
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ToolFloatParserTests`
Expected: FAIL to compile — every other `ToolFloat(...)` construction now misses `dir:`.

In `Sources/ZenTerm/ToolFloatFormOverlay.swift`'s `buildFloat()`, preserve the editing float's value (the form control lands in Task 5) so an edit doesn't silently drop a pinned directory:

```swift
            command: command,
            dir: editingFloat?.dir,
```

Then give the `TabControllerToolFloatTests` spec helper a `dir` parameter, so the new tests can ask for a pinned float in one line instead of rebuilding the struct field-by-field:

```swift
    private func spec(
        _ id: String, persist: ToolFloat.Persistence, git: Bool = false, dir: URL? = nil
    ) -> ToolFloat {
        ToolFloat(
            id: id, title: "Open \(id)", icon: ToolFloatParser.defaultIcon, command: id, dir: dir,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: git,
            persist: persist, toggle: Chord(command: true, shift: true, key: "j"))
    }
```

Add `dir: nil` to the other test constructions — `ToggleDockTests.swift`, `ToolFloatFormOverlayTests.swift` (two sites), `ConfigWriterTests.swift`, `KeymapAssemblyTests.swift`. Find them all with `grep -rn "ToolFloat(" Tests/`. Re-run. Expected: PASS.

- [ ] **Step 6: Serialize `dir:`**

In `Sources/ZenTerm/ConfigWriter.swift`, in `serializeFloat`, add after the `command:` token:

```swift
        tokens.append("command:\(quotedValue(float.command))")
        if let dir = float.dir { tokens.append("dir:\(quotedValue(dir.path))") }
```

- [ ] **Step 7: Write the failing engine test**

Add to `Tests/ZenTermTests/TabControllerToolFloatTests.swift`:

```swift
func test_dirField_pinsTheSpawnDirectory_ignoringTheFocusedCWD() throws {
    let paneDir = try makeDir("pane", git: false)
    let pinned = try makeDir("notes", git: false)
    let (controller, spawned) = makeController(cwd: paneDir)

    controller.toggleToolFloat(spec("notes", persist: .ephemeral, dir: pinned))

    XCTAssertEqual(
        floatSurfaces(spawned(), command: "notes")[0].lastConfig?.workingDirectory, pinned,
        "a pinned dir: must win over the focused pane's cwd")
}

func test_dirField_withPersistTab_survivesACWDChange() throws {
    let paneDir = try makeDir("pane", git: false)
    let pinned = try makeDir("notes", git: false)
    let elsewhere = try makeDir("elsewhere", git: false)
    let (controller, spawned) = makeController(cwd: paneDir)
    let float = spec("notes", persist: .tab, dir: pinned)

    controller.toggleToolFloat(float)
    controller.closeToolFloat()
    paneSurface(spawned()).currentDirectory = elsewhere
    controller.toggleToolFloat(float)

    XCTAssertEqual(floatSurfaces(spawned(), command: "notes").count, 1)
}
```

- [ ] **Step 8: Run test to verify it fails**

Run: `swift test --filter TabControllerToolFloatTests/test_dirField_pinsTheSpawnDirectory_ignoringTheFocusedCWD`
Expected: FAIL — `workingDirectory` is `paneDir`, not `pinned`.

- [ ] **Step 9: Honor `dir:` in the engine**

In `Sources/ZenTerm/TabController.swift`, add next to `directoryAnchor(for:)`:

```swift
    /// Where a float's command runs: its pinned `dir:` when it has one, else the focused pane's cwd.
    private func floatCWD(_ spec: ToolFloat) -> URL? { spec.dir ?? focusedCWD }
```

In `spawnFloatSurface`, use it:

```swift
                workingDirectory: floatCWD(spec), theme: Theme.current.terminal,
```

In `surfaceForFloat`, anchor off it too, so a pinned `.directory` float resolves a constant anchor (which is what makes it behave as `.tab`, matching the parser's warning):

```swift
        let anchor = spec.persist == .directory ? directoryAnchor(for: floatCWD(spec)) : nil
```

- [ ] **Step 10: Run tests to verify they pass**

Run: `swift test --filter TabControllerToolFloatTests`
Expected: PASS, all 11.

- [ ] **Step 11: Document `dir:`**

In `docs/config/config`, add to the float field list after `command`:

```
#   dir      (optional)  pinned working directory, ~ expanded   (default: focused pane's cwd)
#                        for tools that aren't about the directory you're in (a music
#                        player) or that mean a specific one (a notes scratchpad)
```

And add an example:

```
# Example — a system monitor kept alive per tab, spawned at home rather than wherever you were:
# float = id:btop command:"btop" key:cmd+shift+b persist:tab dir:~ icon:gauge
```

- [ ] **Step 12: Run the gate and commit**

Run: `bin/check`
Expected: green.

```bash
git add -A
git commit -m "$(cat <<'EOF'
ZEN-77: add the dir: float field

Pins a float's working directory. Without it a cwd-independent tool (btop, a music
player, an email client) spawns at whatever directory the focused pane happened to
be in on first open, and a notes float can't name the directory it means.

dir: + persist:dir is degenerate — a fixed directory has a fixed identity, so the
re-anchor can never fire and the float behaves exactly as persist:tab. The parser
warns rather than silently reinterpreting intent.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DV9pfKR82fdTLWSwQREbdi
EOF
)"
```

---

### Task 5: Settings form controls

The float editor (Settings → Tools) must author the two new fields, or they're config-file-only and the form silently flattens them on every edit.

**Files:**
- Modify: `Sources/ZenTerm/ToolFloatFormOverlay.swift`
- Test: `Tests/ZenTermTests/ToolFloatFormOverlayTests.swift`

**Interfaces:**
- Consumes: `ToolFloat.persist` (Task 2), `ToolFloat.dir` (Task 4). Existing, already on `SegmentedControl` — do not re-add: `init(options:selectedIndex:notifiesOnReselect:onChange:)`, `private(set) var selectedIndex: Int`, `func select(_ index: Int)` (the real click path — arrows and mouse both route through it, and it fires `onChange`), `func setSelection(_ index: Int)` (programmatic sync, does NOT fire `onChange`), `func reapplyTheme()`. `FieldBox(placeholder:)` has `.text`, `.setText(_:)`, `.placeholder`, `.field`.
- Produces: `SegmentedControl.optionTitles: [String]` — the only new API, so a test can find one of the form's two segmented controls without depending on view order.

> **Order matters for the segment:** the `Persistence` cases must map to segment indices in a fixed order. Use `[.ephemeral, .directory, .tab]` and derive both directions from one array so the mapping can't drift.

- [ ] **Step 1: Write the failing interaction tests**

Add to `Tests/ZenTermTests/ToolFloatFormOverlayTests.swift`. The first function is a harness helper — put it in the `// MARK: harness` section beside `field(in:placeholder:)`, not among the tests:

```swift
/// A segmented control found by its first option's title — the form has two of them.
private func segment(in overlay: NSView, firstOption: String) -> SegmentedControl {
    descendants(of: overlay).compactMap { $0 as? SegmentedControl }
        .first { $0.optionTitles.first == firstOption }!
}
```

The rest go under `// MARK: tests`:

```swift
func test_persistSegment_defaultsToEphemeral_andBuildsTheChosenMode() {
    let (overlay, capturer, sink) = mount()
    field(in: overlay, placeholder: "gitdash").setText("lg")
    field(in: overlay, placeholder: "npm run dev").setText("lazygit")
    capture(novelChord, in: overlay, capturer)

    segment(in: overlay, firstOption: "Fresh each time").select(1)  // Per directory
    submit(in: overlay)

    XCTAssertEqual(sink.submitted.first?.persist, .directory)
}

func test_persistSegment_untouched_buildsEphemeral() {
    let (overlay, capturer, sink) = mount()
    field(in: overlay, placeholder: "gitdash").setText("y")
    field(in: overlay, placeholder: "npm run dev").setText("yazi")
    capture(novelChord, in: overlay, capturer)

    submit(in: overlay)

    XCTAssertEqual(sink.submitted.first?.persist, .ephemeral)
}

func test_dirField_buildsPinnedDirectory() {
    let (overlay, capturer, sink) = mount()
    field(in: overlay, placeholder: "gitdash").setText("notes")
    field(in: overlay, placeholder: "npm run dev").setText("nvim")
    field(in: overlay, placeholder: "~/notes").setText("~/notes")
    capture(novelChord, in: overlay, capturer)

    submit(in: overlay)

    XCTAssertEqual(sink.submitted.first?.dir?.path, NSString(string: "~/notes").expandingTildeInPath)
}

func test_blankDirField_buildsNilDirectory() {
    let (overlay, capturer, sink) = mount()
    field(in: overlay, placeholder: "gitdash").setText("y")
    field(in: overlay, placeholder: "npm run dev").setText("yazi")
    capture(novelChord, in: overlay, capturer)

    submit(in: overlay)

    XCTAssertNil(sink.submitted.first?.dir)
}

/// Editing a float must not silently flatten fields the form didn't previously expose.
func test_edit_prefillsPersistAndDir() {
    let existing = ToolFloat(
        id: "lg", title: "Open Lazygit", icon: "git", command: "lazygit",
        dir: URL(fileURLWithPath: "/tmp/x"), widthFraction: 0.85, heightFraction: 0.78,
        requiresGitRepo: true, persist: .tab, toggle: Chord(command: true, key: "g"))
    let (overlay, _, sink) = mount(editing: existing)

    submit(in: overlay)

    XCTAssertEqual(sink.submitted.first?.persist, .tab)
    XCTAssertEqual(sink.submitted.first?.dir?.path, "/tmp/x")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ToolFloatFormOverlayTests`
Expected: FAIL — no `optionTitles`/`select` on `SegmentedControl`, no field with placeholder `~/notes`.

- [ ] **Step 3: Add `optionTitles` to `SegmentedControl`**

`select(_:)` already exists and is the real click path (the `AppButton` segments call it, and so do Left/Right), so the tests need no new drive API. They do need to tell the form's two segmented controls apart.

In `Sources/ZenTerm/Controls/SegmentedControl.swift`, add the stored property below `selectedIndex`:

```swift
    private(set) var selectedIndex: Int
    /// The segment titles, in order — lets a caller find one of a form's several segmented controls
    /// without depending on view-tree order.
    private(set) var optionTitles: [String]
```

And set it as the first line of `init`, before `self.selectedIndex`:

```swift
        self.optionTitles = options
        self.selectedIndex = selectedIndex
```

- [ ] **Step 4: Declare the persist segment and dir field**

In `Sources/ZenTerm/ToolFloatFormOverlay.swift`, add next to `gitSegment` (~line 34):

```swift
    private let gitSegment = SegmentedControl(options: ["Any folder", "Git repos only"], selectedIndex: 0) { _ in }
    /// Segment index ↔ `Persistence`. One array drives both directions so the mapping can't drift.
    private static let persistOptions: [ToolFloat.Persistence] = [.ephemeral, .directory, .tab]
    private let persistSegment = SegmentedControl(
        options: ["Fresh each time", "Per directory", "Per tab"], selectedIndex: 0) { _ in }
    private let dirField = FieldBox(placeholder: "~/notes")
```

Add the group ivar next to the others (~line 41):

```swift
    private var dirGroup: LabeledField?
```

- [ ] **Step 5: Build the groups and put them in the content stack**

In `buildContent()`, add the dir group right after the `commandGroup` block (~line 194):

```swift
        wireField(dirField)
        let dirGroup = LabeledField(caption: caption("DIRECTORY", required: false), control: dirField)
        self.dirGroup = dirGroup
```

And the persist group right after the `gitGroup` line (~line 219):

```swift
        wireSegment(gitSegment)
        let gitGroup = Self.vStack([caption("OPEN IN", required: false), gitSegment], spacing: 6)

        wireSegment(persistSegment)
        let persistGroup = Self.vStack([caption("KEEP RUNNING", required: false), persistSegment], spacing: 6)
```

Then add both to the content stack (~line 249) — `dirGroup` follows the command it qualifies, `persistGroup` follows the other lifetime-ish row:

```swift
        let content = NSStackView(views: [
            header, idGroup, titleGroup, iconGroup, chordGroup, commandGroup, dirGroup, sizeGroup,
            gitGroup, persistGroup, footer,
        ])
```

- [ ] **Step 6: Prefill both when editing**

`prefill()` is the seam for this, not `buildContent` — it's where every other field seeds from `editingFloat`. Add to the end of `prefill()`, after the `gitSegment` line:

```swift
        gitSegment.setSelection(float.requiresGitRepo ? 1 : 0)
        if let dir = float.dir { dirField.setText(dir.path) }
        if let index = Self.persistOptions.firstIndex(of: float.persist) {
            persistSegment.setSelection(index)  // programmatic sync must not fire onChange
        }
```

- [ ] **Step 7: Add both to the keyboard focus ring**

The project's keyboard-first rule means a control that isn't a vertical stop is unreachable without a mouse. Update `verticalStops()`:

```swift
    private func verticalStops() -> [NSView] {
        [
            idField.field, titleField.field, iconPicker, chordChip, commandField.field,
            dirField.field, widthField.field, gitSegment, persistSegment, submitButton,
        ]
    }
```

- [ ] **Step 8: Build both fields into the float**

In `buildFloat()`, replace the `dir:` and `persist:` arguments:

```swift
        let pinnedDir = dirField.text.trimmingCharacters(in: .whitespaces)
        return ToolFloat(
            id: id,
            title: title.isEmpty ? ToolFloatParser.defaultTitle(forID: id) : title,
            icon: iconPicker.selected,
            command: command,
            dir: pinnedDir.isEmpty
                ? nil : URL(fileURLWithPath: NSString(string: pinnedDir).expandingTildeInPath).standardizedFileURL,
            widthFraction: fraction(widthField),
            heightFraction: fraction(heightField),
            requiresGitRepo: gitSegment.selectedIndex == 1,
            persist: Self.persistOptions[persistSegment.selectedIndex],
            toggle: chord)
```

- [ ] **Step 9: Add the new controls to the theme re-apply pass**

A live theme change would otherwise leave them stale. In `reapplyTheme()` (~line 140), add both to the controls array and `dirGroup` to the group loop:

```swift
        let controls: [ThemeReapplying] = [
            idField, titleField, commandField, dirField, widthField, heightField, gitSegment,
            persistSegment, cancelButton, submitButton, deleteButton,
        ]
        controls.forEach { $0.reapplyTheme() }
        chordChip.reapplyTheme()
        iconPicker.reapplyTheme()
        for group in [idGroup, titleGroup, iconGroup, chordGroup, commandGroup, dirGroup, sizeGroup] {
            group?.reapplyTheme()
        }
```

- [ ] **Step 10: Run tests to verify they pass**

Run: `swift test --filter ToolFloatFormOverlayTests`
Expected: PASS — the 12 existing tests plus the 5 new ones.

- [ ] **Step 11: Run the gate**

Run: `bin/check`
Expected: green.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
ZEN-77: author persist: and dir: from the Settings float form

Without these controls the two fields are config-file-only, and the form silently
flattens them every time a float is edited.

Both join verticalStops() so they're reachable without a mouse, per the project's
keyboard-first rule, and the persist segment maps to Persistence through a single
array so the index mapping can't drift.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DV9pfKR82fdTLWSwQREbdi
EOF
)"
```

---

## Manual runbook

`bin/check` covers the logic; these are the behaviors no test can assert. **Hand these to Drew** — the tool shell can't drive the GUI (macOS TCC blocks screenshots and synthetic keystrokes).

Add to `~/.config/zen-term/config`:

```
float = id:lazygit command:"lazygit" key:cmd+g git:true persist:dir icon:git title:"Open Lazygit" height:0.78
float = id:yazi command:"yazi" key:cmd+shift+y title:"Open Yazi"
float = id:btop command:"btop" key:cmd+shift+b persist:tab dir:~ icon:gauge
```

Run `swift run ZenTerm`, then check:

1. **Persistence is visible.** ⌘G, navigate lazygit into a diff or a stash, dismiss, ⌘G again — it comes back exactly where you left it, instantly. That preserved scroll/cursor state is the whole feature.
2. **Ephemeral is unchanged.** ⌘⇧Y, move around in yazi, dismiss, reopen — it's a fresh yazi at the top. (Note: ⌘G still routes to the *bespoke* lazygit in this PR — ZEN-140 deletes that. Expect the config lazygit float to need a different chord until then.)
3. **Re-anchoring.** With a lazygit float open in repo A, dismiss, `cd` to repo B in the pane, reopen — it shows repo B. `cd` to a *subdirectory* of B, reopen — same instance, no reload.
4. **`dir:`.** ⌘⇧B from any directory — btop's shell is at `~`, not wherever you were.
5. **No leaks.** Open all three, ⌘W the tab, and confirm in Activity Monitor that no lazygit/btop process survives.
6. **The form round-trips.** Settings → Tools → edit the btop float → Save. Confirm the config file still has `persist:tab dir:...` and that the fields prefilled correctly.

## Ship

Per `.claude/skills/ship-feature/`: `bin/check` green → push branch → draft PR referencing ZEN-77 → Copilot review + `/code-review` on the branch diff → triage every finding (fix / mitigate / ignore, **no tech debt**; residual work becomes a Linear ticket, never an in-code `TODO`) → re-run `bin/check` → ZEN-77 to **In Review** (`c8f755f6-5c17-4bdd-b41f-9161166fdb19`) → mark the PR ready.

Branch: `feature/zen-77-tool-floats-one-configurable-lifecycle-persist-nonedirtab` (already created, spec already committed on it).

**Follow-ups, already filed — do not fold them into this PR:** ZEN-140 (delete the bespoke lazygit path), ZEN-141 (`persist:window`).
