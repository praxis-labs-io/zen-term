# Tool float lifecycle — one `persist:` field (ZEN-77 / ZEN-140 / ZEN-141)

**Goal:** replace the hardcoded ephemeral-only float lifecycle with a single
configurable `persist:` field, and retire the bespoke lazygit path it makes
redundant. A float can then keep its process alive across close/reopen, scoped to a
directory, a tab, or a window.

Design decisions (confirmed): "global" means **per-window**, not per-app; **no
pre-warm** anywhere, including ripping out lazygit's; the bespoke lazygit path is
**deleted** (lazygit becomes a config line); add a `dir:` field; delete `EmptyGuard`.

## Why now

ZEN-36 made tool floats ephemeral on purpose — "a diff is a point-in-time snapshot
that goes stale the instant you edit or commit, so DiffNav must be the opposite —
spawn-fresh on open, terminate on close" — and explicitly left lazygit alone: *"Lazygit
keeps its own path; folding it in would re-touch just-shipped ZEN-48 persistence for no
gain here."*

That was right then and is wrong now. The gain is here:

- **Lazygit is hardcoded chrome for a tool we don't ship.** ⌘G, an overlay subclass, a
  pre-warm pool, and a dedicated modal gate all exist for a binary that isn't bundled.
  ZEN-71 already established that no float is built in — a float's chord comes from its
  own `key:` field. Lazygit is the last violation.
- **Every user float is stuck ephemeral.** `gh dash` re-pays its startup on every open.
  A music player, process monitor, or email client can't stay alive at all.

## The model

Scope only exists when a float is persistent. An ephemeral tool spawns fresh at the
focused cwd every open, so "which tab does it belong to" has no referent — there's no
instance to belong. **One field, not three:**

```
persist: none | dir | tab | window      # default: none (today's behavior)
```

| value | meaning | tools |
|---|---|---|
| `none` *(default)* | Terminate on dismiss. Fresh spawn at the focused cwd every open. | yazi, scratch terminal |
| `dir` | One live instance per **directory identity**, per tab. Same dir → same instance. Different dir → discard + respawn. Two tabs in one repo means two instances — that is today's lazygit behavior, preserved. | lazygit, dev server |
| `tab` | One live instance per tab, anchored at first-open cwd. Never re-anchors. | process monitor |
| `window` | One live instance per window, reachable from every tab. | gitdash, btop, music, email |

The values are derived from real tools, not invented: each of yazi, lazygit, gitdash,
btop, a process monitor, and a music/email client lands in exactly one cell.

### `dir`, not `repo`

The directory identity already exists — it's what lazygit anchors to today:

```swift
// TabController.swift — the semantic being generalized
private func lazygitAnchor(for cwd: URL?) -> URL? {
    gitRepoRoot(for: cwd) ?? cwd?.standardizedFileURL
}
```

It falls back to the plain cwd outside a repo, so it is a *directory* identity that
treats a repo as one directory — not a git concept. Naming the value `repo` would lie
about that and would wrongly imply non-git tools can't use it. A `git:true` float still
gates on being inside a repo; that's the separate, existing `requiresGitRepo` field.

### `dir:` — a pinned working directory

```
dir: <path>     # optional; ~ expanded. Unset = the focused pane's cwd.
```

Cwd-independent tools (btop, music, email) would otherwise spawn at whatever directory
the focused pane happened to be in on first open, and a notes float or a dev server has
a directory it actually means.

`dir:` + `persist:dir` is **degenerate**: a fixed directory has a fixed identity, so the
re-anchor can never fire and the mode collapses into exactly `persist:tab` (the registry
is per-tab either way). The parser warns and the author should write `persist:tab` if
that's what they meant. `dir:` composes cleanly with `none`, `tab`, and `window`.

## Ownership

The split follows the lifetime, and an AppKit constraint forces it rather than taste.

### `none` / `dir` / `tab` → `TabController`

- `activeToolFloat` keeps its current meaning: **which float is shown**.
- New `persistentFloats: [String: (surface: TerminalSurface, anchor: URL?)]`: what is
  **alive**. Liveness and visibility become independent — which is exactly how lazygit
  already models it (`isLazygitOpen` is `lazygitOverlay != nil`, not surface existence).
- **Dismiss:** `.none` terminates (today's path). Otherwise drop the overlay, keep the
  surface, leave the registry entry.
- **Reopen:** registry hit → rebuild a `SurfaceFloatOverlay` around the retained
  `surface.view`, after snapping away any still-animating outgoing overlay. A
  springing-out card still holds Auto Layout constraints on the shared view;
  `showLazygit` already does this dance and it's load-bearing.
- **Terminate:** `shutdown()`. Process self-exit clears the registry entry and the next
  open spawns fresh — there is no re-warm rule to preserve, because pre-warm is gone.

### `window` → `WindowController`

This is the only genuinely new architecture, and it hinges on one hazard.

`presentModal` hosts modal cards via `active.presentTileOverlay(overlay)`, which pins to
the **active tab's** content view. That's precisely why `closeModal()` must run before
any tab-bar operation — it "would otherwise unmount the card's host tab and leave the
gate stuck on."

A window float must survive tab switches, so it cannot use that path. It hosts on
`container`, the window-level layer `ToastPresenter` already uses ("window-level so it's
shared by every tab"). Hosting there means **no reparenting on tab switch and no unmount
hazard**. Width/height fractions, which today resolve against the tab's tile region,
must resolve the same rect at window level.

`WindowController` gains `windowFloats: [String: (surface, overlay)]`, terminated on
window close.

**Per-window, not per-app** — a surface is one `NSView` and can only live in one view
hierarchy. An app-global instance would physically yank the float out of window A when
opened in window B.

## Deletions

The majority of the diff, and most of the value.

**Pre-warm, entirely.** `LazygitPrewarmPool.swift` and its 6 unit tests,
`schedulePrewarmLazygit`, `prewarmLazygitNow`, `prewarmWorkItem`, `prewarmDelay`,
`hasStablePath`, the `applyRecipe` prewarm call, and the
`TabController.init(prewarmPool:prewarmDelay:)` params — which also un-breaks an
unrelated coupling where a *drawer* test has to pass a prewarm pool into the initializer.

The cost is owned: the first ⌘G per repo goes cold. Every open after that is instant.

`hasStablePath` deserves a note, because deleting it removes a fiction. It is
`pinnedTitle != nil` — it infers "this tab has a stable repo path" from the *title* being
pinned, because **there is no first-class notion of "the tab's repo" anywhere in the
codebase**. `applyRecipe` ignores `Workspace.path` entirely; the only per-tab repo state
in existence is `lazygitLaunchAnchor`. `persist:dir` replaces the proxy with a real
per-float anchor.

**Bespoke lazygit.** The `MARK: lazygit float` block, keeping only `gitRepoRoot` and
`restoreUnifiedFocus`. Plus `.toggleLazygit` (`KeyInterceptor`, `Keybinds`' ⌘G default,
`CommandCatalog`, `SettingsKeybindsSection`), `ToggleDock`'s `lazygitBtn`/`onLazygit`,
`WindowController`'s lazygit gate and its cross-references in the modal and tool-float
gates, and `OverlayState.isLazygitOpen` (`activeToolFloatID` already covers it).

**`LazygitOverlay.swift`** — 19 lines, zero overrides, differs from a direct
`SurfaceFloatOverlay` only in `heightFraction: 0.78` vs the `0.85` default.

**`EmptyGuard`** — the type, `probingToolFloatID`, the background-queue probe, and its
2-second timeout watchdog. It was built for a diff float that shipped as gitdash instead,
and `ToolFloatParser` hardcodes `emptyGuard: nil`, so no config can author one. Deleting
it removes a whole async path from the engine.

**Cleanup while in here:** move `gitRepoRoot(for:)` from `TabController`'s privates to
`GitRepo.swift` beside `isGitRepo`. After the deletion its only caller is the float
engine, and it's the codebase's only repo-root walker.

## Behavior preserved without special-casing

- **Float-switching.** The tool-float gate's `.toggleToolFloat` case is unparameterized,
  so float B's chord while float A is open falls through to `toggleToolFloat(B)` →
  `closeToolFloat()` → open B. Lazygit-as-float inherits this.
- **The `.closePane` toast.** `"Close lazygit first to close a pane."` is hardcoded today;
  the tool-float gate derives the same string from the spec title.
- **Dock position.** `lazygitBtn` is the last fixed button, immediately before the
  config-order float cluster, so a lazygit float lands in the same visual slot.
- **The `git` icon.** `icon:git` is already a documented config value backed by the
  bundled mark in `Resources/git.svg`.

## Migration

- **⌘G becomes unbound by default.** Ship the recipe commented in `docs/config/config`:
  ```
  float = id:lazygit command:"lazygit" key:cmd+g git:true persist:dir icon:git title:"Open Lazygit" height:0.78
  ```
  `height:0.78` gives pixel parity with today's `LazygitOverlay`.
- **An existing `keybind = toggle_lazygit=cmd+g` is silently dropped** —
  `ReservedChord(token:)` returns nil and the line is skipped. The warning must name the
  removed action rather than just saying "unknown action".
- **Lazygit's chord moves** from Settings → Keybinds to Settings → Tools. Float toggles
  are deliberately excluded from the keybinds UI ("they're file-only"), so this is
  consistent — but it moves.

## Delivery

Three PR-sized tickets. ZEN-140 depends on ZEN-77 (lazygit parity needs `persist:dir`).

1. **ZEN-77 — per-tab lifecycle.** `persist:none|dir|tab` + `dir:`. Parser,
   `ConfigWriter.serializeFloat` round-trip, the `TabController` registry, `EmptyGuard`
   deletion, `ToolFloatFormOverlay` persist/dir controls, docs, tests. Lazygit untouched;
   purely additive.
2. **ZEN-140 — delete bespoke lazygit.** The deletion list + config recipe + migration
   warning. Near-pure deletion, independently reviewable.
3. **ZEN-141 — window-scoped floats.** `persist:window` + the `container`-hosted overlay
   + window-level geometry. Lands last, on a cleaned-up engine.

## Testing

Per the project rule, AppKit controls get **window-based interaction tests, not
state-only tests**. `TabControllerLazygitTests` is the template — window-mounted
controller, `RecordingSurface` factory, spawn filtering by args. Six of its eight tests
die with pre-warm, but its harness (`makeController`, `recipe(at:)`, `drainMainQueue`,
`makeDir(_:git:)`) is what the new suite is built on.

- `persist:none` → dismiss terminates (regression guard on today's behavior).
- `persist:dir` → dismiss keeps alive; reopen in the same dir reuses the **same** surface
  instance; reopen after the anchor changes discards + respawns; a non-repo cwd anchors to
  the plain cwd (the `?? cwd` fallback).
- `persist:tab` → survives dismiss; does **not** re-anchor on cwd change; dies on
  `shutdown()`.
- `persist:window` → one instance across two tabs, and it survives a tab switch while
  shown. That second assertion is what catches the unmount hazard.
- Process self-exit clears the registry; the next open spawns fresh.
- Parser: `persist:` round-trips through `ConfigWriter`; an unknown value warns and
  defaults to `none`; `dir:` + `persist:dir` warns.

Collateral compile breaks to fix: `TabControllerSurfaceFailureTests`, `ToggleDockTests`,
`CommandCatalogTests`, `KeybindParserTests`, and `KeymapAssemblyTests` — the last needs a
new displacement subject (e.g. `.toggleZoom` on ⌘F) since `.toggleLazygit` disappears.

**Manual runbook** (lifecycle behavior no test can assert): a configured lazygit float →
⌘G opens; `q` closes and the next ⌘G is cold; dismiss + reopen is instant and preserves
scroll/selection state; `cd` to another repo → ⌘G shows the new repo; a `persist:window`
btop stays alive and reachable from a second tab.

## Ship

`bin/check` green → `/code-review` → triage (no tech debt) → ticket to In Review.
