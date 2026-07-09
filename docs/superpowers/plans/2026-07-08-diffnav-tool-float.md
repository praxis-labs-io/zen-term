# DiffNav Tool-Float Engine — Implementation Plan (ZEN-36)

> **For agentic workers:** execute task-by-task; each task ends green on
> `bin/check` (build + `swift test` + `swift format lint --strict` +
> `swiftlint --strict`). AppKit wiring with no unit seam is verified by the
> manual runbook at the end, per `CLAUDE.md`.

**Goal:** add a `⌘⇧G` DiffNav float (`git diff main` via the user's diffnav pager)
built on a reusable, ephemeral **tool-float engine** so the next float is one spec
+ one keybinding line.

**Architecture:** a declarative `ToolFloat` spec + `ToolFloatCatalog` drives a
generic `toggleToolFloat`/`closeToolFloat` engine on `TabController` (spawn-fresh,
terminate-on-close), reusing `SurfaceFloatOverlay`, `gitRepoRoot`, and the toast
infra. A generalized `.toggleToolFloat(String)` chord dispatches by id; the dock
button and palette entry auto-derive from the catalog. Lazygit is untouched.

**Tech stack:** Swift + AppKit + SwiftPM. Chrome lives in `Sources/ZenTerm/`.

## Context

Branch `feature/zen-36-new-diff-nav-float` is off `main` (has the merged ZEN-48
persistent lazygit float; does NOT have the unmerged ZEN-49 confirm work — no
interaction). The lazygit float (`TabController.toggleLazygit`/`showLazygit`/
`ensureLazygitSurface` etc.) is the pattern to mirror for the *plumbing*; DiffNav
is ephemeral, so it terminates on close instead of persisting. Design source of
truth: `docs/superpowers/specs/2026-07-08-diffnav-tool-float-design.md`.

## Global Constraints

- `Sources/ZenTerm/` must never `import SwiftTerm`. No `TODO`/`FIXME`/`HACK`; no
  force-unwrap except documented AppKit. One primary type per file; filename
  matches the type; PascalCase types.
- **diffnav spec (verbatim):** id `"diffnav"`, title `"Open Diff Nav"`, shortcut
  `"⌘⇧G"`, icon `"plus.forwardslash.minus"`, command `"git diff main"`,
  `widthFraction 0.85`, `heightFraction 0.85`, `requiresGitRepo true`, empty-guard
  probe `"git diff main --quiet"` with toast (symbol `"checkmark.circle.fill"`,
  title `"No changes vs main"`, message `"Your branch matches main — nothing to
  diff."`).
- **Keybinding:** `⌘⇧G` → `.toggleToolFloat("diffnav")`.
- **Ephemeral:** spawn a fresh surface on open; **terminate** on every close
  (`⌘⇧G` / `⌘W` / backdrop / `q` inside diffnav). No persist, no pre-warm.
- **Not-a-git-repo toast is generic** (not tool-named): title `"Not a Git
  repository"`, message `` "Open a repo or run `git init` here." ``.
- **Lazygit is untouched.** The engine instantiates `SurfaceFloatOverlay`
  directly (no per-float overlay subclass).

---

## Task 1 — `ToolFloat` spec + catalog

**Files:**
- Create: `Sources/ZenTerm/ToolFloat.swift`
- Create: `Tests/ZenTermTests/ToolFloatCatalogTests.swift`

**Produces:** `ToolFloat` (struct), `EmptyGuard` (struct), `ToolFloatCatalog`
(`static let all: [ToolFloat]`, `static func byID(_:) -> ToolFloat?`).

- [ ] **Step 1: Write the failing test** — `Tests/ZenTermTests/ToolFloatCatalogTests.swift`

```swift
import XCTest

@testable import ZenTerm

final class ToolFloatCatalogTests: XCTestCase {
    func test_ids_areUnique() {
        let ids = ToolFloatCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "ToolFloat ids must be unique")
    }

    func test_diffnav_isPresentWithExpectedSpec() {
        let f = ToolFloatCatalog.byID("diffnav")
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.command, "git diff main")
        XCTAssertEqual(f?.shortcut, "⌘⇧G")
        XCTAssertEqual(f?.widthFraction, 0.85)
        XCTAssertEqual(f?.heightFraction, 0.85)
        XCTAssertTrue(f?.requiresGitRepo == true)
        XCTAssertEqual(f?.emptyGuard?.probe, "git diff main --quiet")
    }

    func test_byID_unknown_isNil() {
        XCTAssertNil(ToolFloatCatalog.byID("nope"))
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (no `ToolFloatCatalog`)

`swift test --filter ToolFloatCatalogTests` → fails to compile / "cannot find 'ToolFloatCatalog'".

- [ ] **Step 3: Create `Sources/ZenTerm/ToolFloat.swift`**

```swift
import AppKit

/// A declarative ephemeral command float. Everything variable about a float lives
/// here; the tool-float engine on `TabController` does the rest. Add a float by
/// adding a value to `ToolFloatCatalog.all` and one keybinding in `KeyInterceptor`.
struct ToolFloat: Equatable {
    let id: String            // stable id, e.g. "diffnav"
    let title: String         // command-palette title, e.g. "Open Diff Nav"
    let shortcut: String      // palette glyph string, e.g. "⌘⇧G" (display only)
    let icon: String          // dock SF Symbol, e.g. "plus.forwardslash.minus"
    let command: String       // runs as `$SHELL -l -i -c command` at the focused pane's cwd
    let widthFraction: CGFloat
    let heightFraction: CGFloat
    let requiresGitRepo: Bool
    let emptyGuard: EmptyGuard?
}

/// A pre-open probe: run `probe` at the focused cwd; if it exits 0 (nothing to
/// show), skip opening the float and surface `toast` instead.
struct EmptyGuard: Equatable {
    let probe: String
    let toast: ToastContent
}

/// The registered ephemeral tool floats. Adding an entry here (plus one
/// `KeyInterceptor` mapping) is all it takes to add a float — the dock button,
/// palette entry, git guard, and toggle behavior all derive from the spec.
enum ToolFloatCatalog {
    static let all: [ToolFloat] = [
        ToolFloat(
            id: "diffnav",
            title: "Open Diff Nav",
            shortcut: "⌘⇧G",
            icon: "plus.forwardslash.minus",
            command: "git diff main",
            widthFraction: 0.85,
            heightFraction: 0.85,
            requiresGitRepo: true,
            emptyGuard: EmptyGuard(
                probe: "git diff main --quiet",
                toast: ToastContent(
                    symbol: "checkmark.circle.fill",
                    title: "No changes vs main",
                    message: "Your branch matches main — nothing to diff."))),
    ]

    static func byID(_ id: String) -> ToolFloat? { all.first { $0.id == id } }
}
```

- [ ] **Step 4: Run — expect PASS**

`swift test --filter ToolFloatCatalogTests` → 3 tests pass.

- [ ] **Step 5: Gate + commit**

```bash
bin/check
git add Sources/ZenTerm/ToolFloat.swift Tests/ZenTermTests/ToolFloatCatalogTests.swift
git commit -m "feat(toolfloat): ToolFloat spec + catalog with diffnav

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 — Tool-float engine on `TabController`

**Files:**
- Modify: `Sources/ZenTerm/TabController.swift`

**Consumes:** `ToolFloat`/`ToolFloatCatalog` (Task 1); existing `gitRepoRoot(for:)`
(:369), `onRequestToast` (:136), `presentTileOverlay` (:201), `restoreUnifiedFocus`
(:461), `exitZoomIfNeeded` (:569), `SurfaceFloatOverlay` (base), `focusedCWD`
(:124), `ShellLaunch.userShell`/`defaultCWD`.
**Produces:** `TabController.isToolFloatOpen: Bool`, `.activeToolFloatID: String?`,
`toggleToolFloat(_ spec: ToolFloat)`, `closeToolFloat()`;
`OverlayState.activeToolFloatID: String?`.

- [ ] **Step 1: Add `activeToolFloatID` to `OverlayState`** (TabController.swift:13-18)

```swift
struct OverlayState: Equatable {
    var isBottomOpen = false
    var isRightOpen = false
    var isLazygitOpen = false
    var activeToolFloatID: String?
    var zoomed: ZoomedPanel?
}
```

- [ ] **Step 2: Add the engine state + methods.** Place after the lazygit
  properties/methods block (e.g. after `restoreUnifiedFocus()`, ~line 467). Add
  the stored slot near the lazygit vars (after line 75, `isLazygitOpen`):

```swift
    /// The single live ephemeral tool float (diffnav, …). Tool floats are modal and
    /// mutually exclusive, so one slot suffices. Terminated on close (not persisted).
    private var activeToolFloat: (spec: ToolFloat, surface: TerminalSurface, overlay: SurfaceFloatOverlay)?
    var isToolFloatOpen: Bool { activeToolFloat != nil }
    var activeToolFloatID: String? { activeToolFloat?.spec.id }
```

  And the methods (after `restoreUnifiedFocus()`):

```swift
    // MARK: tool floats (ephemeral command floats — diffnav, …)

    /// Toggle a tool float: same id open → close; otherwise run the guards and open a
    /// fresh surface. Mirrors `toggleLazygit`'s plumbing but spawns fresh each time.
    func toggleToolFloat(_ spec: ToolFloat) {
        if activeToolFloat?.spec.id == spec.id { closeToolFloat(); return }
        if activeToolFloat != nil { closeToolFloat() }  // switch floats
        if spec.requiresGitRepo, gitRepoRoot(for: focusedCWD) == nil {
            onRequestToast?(
                ToastContent(
                    symbol: "exclamationmark.triangle.fill",
                    title: "Not a Git repository",
                    message: "Open a repo or run `git init` here."))
            return
        }
        if let guardSpec = spec.emptyGuard, probeIsEmpty(guardSpec.probe) {
            onRequestToast?(guardSpec.toast)
            return
        }
        exitZoomIfNeeded()  // zoom and the float are mutually exclusive
        showToolFloat(spec)
    }

    /// Spawn `spec.command` in a fresh login+interactive shell at the focused cwd (so
    /// the user's git pager / PATH match a pane), present it in a `SurfaceFloatOverlay`,
    /// and give it the tab's unified focus. When the command exits, `surfaceDidExit`
    /// tears the float down.
    private func showToolFloat(_ spec: ToolFloat) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let surface = TerminalSurfaceFactory.make()
        surface.delegate = self
        surface.start(
            TerminalSurfaceConfig(
                command: shell, args: ["-l", "-i", "-c", spec.command],
                workingDirectory: focusedCWD, theme: Theme.rosePineMoon))
        let overlay = SurfaceFloatOverlay(
            content: surface.view,
            background: Theme.rosePineMoon.background.nsColor,
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

    /// Close the float and TERMINATE its surface (ephemeral — no persistence). Clears
    /// the slot before terminate so a synchronous `surfaceDidExit` re-entry no-ops.
    func closeToolFloat() {
        guard let active = activeToolFloat else { return }
        activeToolFloat = nil
        let overlay = active.overlay
        overlay.animateOut { overlay.removeFromSuperview() }
        active.surface.terminate()
        restoreUnifiedFocus()
        onOverlayStateChanged?()
    }

    /// Run `probe` as a plain (non-login) shell at the focused cwd; exit 0 ⇒ nothing to
    /// show. Used by a float's `emptyGuard` to toast instead of opening an empty float.
    private func probeIsEmpty(_ probe: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ShellLaunch.userShell)
        process.arguments = ["-c", probe]
        process.currentDirectoryURL = focusedCWD ?? ShellLaunch.defaultCWD
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false  // couldn't probe → don't block opening the float
        }
        return process.terminationStatus == 0
    }
```

- [ ] **Step 3: Wire `activeToolFloatID` into `overlayState`** (TabController.swift:128-132)

```swift
    var overlayState: OverlayState {
        OverlayState(
            isBottomOpen: isBottomOpen, isRightOpen: isRightOpen,
            isLazygitOpen: isLazygitOpen, activeToolFloatID: activeToolFloatID,
            zoomed: zoomedPanel.map(\.asZoomed))
    }
```

- [ ] **Step 4: Teardown + focus + copy/paste.**

  In `surfaceDidExit(_:code:)` (line 849), add BEFORE the `if s === lazygitSurface`
  block (bind `active` first so the overlay is captured before the slot is cleared):

```swift
        if let active = activeToolFloat, s === active.surface {
            // The tool ran to completion / quit (`q` in diffnav) → close the float.
            activeToolFloat = nil
            active.overlay.animateOut { active.overlay.removeFromSuperview() }
            active.surface.terminate()
            restoreUnifiedFocus()
            onOverlayStateChanged?()
            return
        }
```

  In `shutdown()` (after line 235, `discardLazygitSurface()`):

```swift
        activeToolFloat?.overlay.removeFromSuperview()
        activeToolFloat?.surface.terminate()
        activeToolFloat = nil
```

  In `restoreKeyFocus()` (line 218-221), keep focus on an open tool float too:

```swift
    func restoreKeyFocus() {
        if isLazygitOpen { lazygitSurface?.focus(); return }
        if let active = activeToolFloat { active.surface.focus(); return }
        restoreUnifiedFocus()
    }
```

  In `copyFromSurface` (line 244) and `pasteToSurface` (line 258), route to the
  visible modal float (lazygit or tool float — they're mutually exclusive):

```swift
        guard let surface = (isLazygitOpen ? lazygitSurface : nil)
            ?? (isToolFloatOpen ? activeToolFloat?.surface : nil)
            ?? focusedDrawerSurface
        else {
```

- [ ] **Step 5: Gate + commit**

```bash
bin/check
git add Sources/ZenTerm/TabController.swift
git commit -m "feat(toolfloat): ephemeral tool-float engine on TabController

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Note: the engine methods are unused until Task 3 dispatches the chord — the build
is green regardless (Swift doesn't warn on unused internal methods).

---

## Task 3 — Chord + palette (`.toggleToolFloat`)

**Files:**
- Modify: `Sources/ZenTerm/KeyInterceptor.swift`
- Modify: `Sources/ZenTerm/CommandCatalog.swift`
- Modify: `Sources/ZenTerm/WindowController.swift`

**Consumes:** `ToolFloatCatalog` (Task 1); `TabController.toggleToolFloat` (Task 2).
**Produces:** `KeyInterceptor.ReservedChord.toggleToolFloat(String)`.

Adding the enum case breaks every **exhaustive** `switch` over `ReservedChord`
until each is updated — those are `CommandCatalog.spec(for:)` and the main switch
in `WindowController.handle`. This task updates all three files together so the
build stays green. (Grep `case .toggle` / `switch chord` to confirm no others.)

- [ ] **Step 1: Add the chord** — `KeyInterceptor.swift`. In `enum ReservedChord`
  (after `.toggleLazygit`, line 19):

```swift
        case toggleToolFloat(String)  // associated value = ToolFloat.id
```

  In the `[.command, .shift]` branch (after `case "p": chord = .toggleRepoPicker`,
  line 48):

```swift
                case "g": chord = .toggleToolFloat("diffnav")  // ⌘⇧G — per-float keybinding
```

- [ ] **Step 2: Palette entry** — `CommandCatalog.swift`. In `spec(for:)` (before
  the `.newWindow` line, ~46):

```swift
        case .toggleToolFloat(let id):
            let f = ToolFloatCatalog.byID(id)
            return tool(f?.title ?? id, f?.shortcut ?? "", chord)
```

  In `commands(tabCount:)` (line 56-60), insert the catalog's floats after
  `.toggleLazygit`:

```swift
        var chords: [KeyInterceptor.ReservedChord] = [
            .toggleRepoPicker, .toggleLazygit,
        ]
        chords += ToolFloatCatalog.all.map { .toggleToolFloat($0.id) }
        chords += [
            .toggleBottomDrawer, .toggleRightDrawer,
            .newTab, .prevTab, .nextTab,
        ]
```

- [ ] **Step 3: Dispatch** — `WindowController.swift`, main switch in `handle(_:)`
  (after `case .toggleLazygit`, line 508):

```swift
        case .toggleToolFloat(let id):
            if let spec = ToolFloatCatalog.byID(id) { active?.toggleToolFloat(spec) }
```

- [ ] **Step 4: Gate + verify.** `bin/check` green (compile proves every
  exhaustive switch is covered). Run `swift run ZenTerm`, press `⌘⇧G` in a git
  repo → the diffnav float opens (modal gate + dock come in Task 4). `q` closes it.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/KeyInterceptor.swift Sources/ZenTerm/CommandCatalog.swift Sources/ZenTerm/WindowController.swift
git commit -m "feat(toolfloat): ⌘⇧G chord + palette entry + dispatch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4 — Modal gate + dock button (integration + runbook)

**Files:**
- Modify: `Sources/ZenTerm/WindowController.swift`
- Modify: `Sources/ZenTerm/ToggleDock.swift`

**Consumes:** `ToolFloatCatalog` (Task 1); `TabController.isToolFloatOpen` /
`closeToolFloat` / `activeToolFloatID` (Task 2); `.toggleToolFloat` (Task 3);
`OverlayState.activeToolFloatID` (Task 2).

- [ ] **Step 1: Modal gate** — `WindowController.handle`, after the lazygit gate
  (after line 482):

```swift
        // Tool floats (diffnav, …) are modal over the tab, like lazygit. ⌘W and the
        // float's own toggle close it; cross-tab/window chords still act. The lazygit
        // gate above doesn't allow .toggleToolFloat and this doesn't allow
        // .toggleLazygit, so the two float families are mutually exclusive.
        if active?.isToolFloatOpen == true {
            switch chord {
            case .closePane:
                active?.closeToolFloat()  // ⌘W closes the float (doesn't close the pane/tab)
                return
            case .toggleToolFloat, .newTab, .newWindow, .selectTab, .prevTab, .nextTab:
                break
            default:
                return
            }
        }
```

- [ ] **Step 2: `ToggleDock` renders catalog buttons.** Rewrite
  `ToggleDock.swift`'s init to accept the catalog + one handler, build a button per
  spec after `lazygitBtn`, and light them by id.

  Add the stored map (after line 13, `lazygitBtn`):

```swift
    private var toolFloatBtns: [String: IconButton] = [:]
```

  Extend the initializer signature (after `onLazygit`):

```swift
        onLazygit: @escaping () -> Void,
        toolFloats: [ToolFloat], onToolFloat: @escaping (ToolFloat) -> Void
```

  After `lazygitBtn = button(...)` (line 32), build the tool-float buttons as
  **locals** (no `self` mutation before `super.init`), then populate the
  `toolFloatBtns` map AFTER `super.init` and append them to the stack:

```swift
        // Local pairs — `button` is a local func, but the `toolFloatBtns` stored
        // property can't be touched until after super.init.
        let toolButtonPairs: [(String, IconButton)] = toolFloats.map { spec in
            (spec.id, button(spec.icon, spec.title, { onToolFloat(spec) }))
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for (id, btn) in toolButtonPairs { toolFloatBtns[id] = btn }

        let stack = NSStackView(views: [
            splitH, splitV, Self.divider(),
            bottomBtn, rightBtn, zoomBtn, Self.divider(),
            paletteBtn, lazygitBtn,
        ] + toolButtonPairs.map(\.1))
```

  In `render(overlay:paletteOpen:)` (after line 62, `lazygitBtn.isActive = …`):

```swift
        for (id, btn) in toolFloatBtns { btn.isActive = overlay.activeToolFloatID == id }
```

- [ ] **Step 3: Wire the dock in `WindowController`.** In `init`, add the handler
  var (near the other `onX` vars, ~line 86):

```swift
        var onToolFloat: (ToolFloat) -> Void = { _ in }
```

  Pass it to the `ToggleDock(...)` init (extend the call, after `onLazygit:`, ~line 90):

```swift
            onLazygit: { onLazygit() },
            toolFloats: ToolFloatCatalog.all, onToolFloat: { onToolFloat($0) })
```

  Wire it after super.init (near `onLazygit = …`, ~line 105):

```swift
        onToolFloat = { [weak self] spec in self?.handle(.toggleToolFloat(spec.id)) }
```

  (`renderDock()` already passes `activeController?.overlayState`, which now carries
  `activeToolFloatID` — no change needed there.)

- [ ] **Step 4: Gate + full manual runbook.** `bin/check` green, then
  `swift run ZenTerm`:
  1. In a git repo with uncommitted/committed changes vs main, `⌘⇧G` → an 85%×85%
     float opens showing `git diff main` rendered by diffnav; the dock button
     (right of lazygit) and the "Open Diff Nav" palette entry are lit/active.
  2. `q` inside diffnav closes it; `⌘⇧G` again closes it; `⌘W` closes it; a
     backdrop click closes it — each terminates the process (reopen re-runs the
     diff, reflecting fresh edits).
  3. On a branch with no diff vs main → `⌘⇧G` shows the "No changes vs main" toast,
     no float.
  4. In a non-repo cwd → `⌘⇧G` shows the "Not a Git repository" toast.
  5. While the float is open, split/nav/drawer/zoom chords are swallowed;
     tab-switch / new-tab / new-window still work.
  6. Lazygit (`⌘G`) and DiffNav (`⌘⇧G`) can't be open simultaneously — opening one
     is blocked while the other is up.
  7. The dock button and palette entry toggle it identically to the chord.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/WindowController.swift Sources/ZenTerm/ToggleDock.swift
git commit -m "feat(toolfloat): modal gate + dock button; wire DiffNav (ZEN-36)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification & ship

- `bin/check` fully green (build, `swift test` incl. `ToolFloatCatalogTests`,
  format lint, swiftlint). Walk the Task 4 runbook via `swift run ZenTerm`.
- `/code-review` on the branch diff; triage every finding (no tech debt); re-run
  `bin/check`. Move Linear **ZEN-36 → In Review**.

## Files at a glance

| File | Change |
| --- | --- |
| `Sources/ZenTerm/ToolFloat.swift` | **new** — `ToolFloat`, `EmptyGuard`, `ToolFloatCatalog` |
| `Tests/ZenTermTests/ToolFloatCatalogTests.swift` | **new** — catalog shape tests |
| `Sources/ZenTerm/TabController.swift` | engine: `toggleToolFloat`/`closeToolFloat`/`showToolFloat`/`probeIsEmpty`, `activeToolFloat`, `OverlayState.activeToolFloatID`, exit/shutdown/focus/copy-paste |
| `Sources/ZenTerm/KeyInterceptor.swift` | `.toggleToolFloat(String)` + ⌘⇧G |
| `Sources/ZenTerm/CommandCatalog.swift` | `spec(for:)` case + catalog floats in `commands` |
| `Sources/ZenTerm/WindowController.swift` | dispatch + modal gate + dock wiring |
| `Sources/ZenTerm/ToggleDock.swift` | catalog-driven tool-float buttons + active tint |
