# DiffNav float via a generalized Tool-Float engine — design (ZEN-36)

**Goal:** add a `⌘⇧G` DiffNav float that shows `git diff main` (rendered through
the user's `pager.diff = diffnav`), and — instead of mirroring the lazygit float
— extract a small, **scalable and repeatable** engine for *ephemeral command
floats* so the next float is one spec + one keybinding line.

Design decisions (confirmed): tool = `diffnav` (the user's default git-diff
pager); range = `git diff main`; toggle = `⌘⇧G`; scope = the **ephemeral** float
family only (lazygit stays on its bespoke persistent path, untouched).

## Why an engine, not a mirror

`SurfaceFloatOverlay` already generalizes the float *chrome* (both `LazygitOverlay`
and a diffnav overlay would be nothing but constants). What still gets
copy-pasted when you add a float is the *plumbing*: a toggle, a git-repo guard +
toast, spawn/present/dismiss, the modal gate, a dock button, a palette entry, and
a keybinding. This design turns that plumbing into one data-driven path.

**Ephemeral vs persistent — the deliberate boundary.** Lazygit (ZEN-48) is
*persistent*: pre-warmed, kept alive when hidden, dir-tracked, re-warmed on quit.
A diff is a point-in-time snapshot that goes stale the instant you edit or commit,
so DiffNav must be the opposite — **spawn-fresh on open, terminate on close**.
The engine targets this ephemeral family (which is what "extend to N floats"
means: run a command in a big float). Lazygit keeps its own path; folding it in
would re-touch just-shipped ZEN-48 persistence for no gain here.

## The spec

```swift
/// A declarative ephemeral command float. Everything variable about a float lives
/// here; the engine does the rest. Add a float by adding a value to the catalog.
struct ToolFloat: Equatable {
    let id: String            // stable id, e.g. "diffnav"
    let title: String         // command-palette title, e.g. "Open Diff Nav"
    let shortcut: String      // palette glyph string, e.g. "⌘⇧G" (display only)
    let icon: String          // dock SF Symbol, e.g. "plus.forwardslash.minus"
    let command: String       // runs as `$SHELL -l -i -c command` at the focused pane's cwd
    let widthFraction: CGFloat
    let heightFraction: CGFloat
    let requiresGitRepo: Bool                 // true → git-repo guard + toast
    let emptyGuard: EmptyGuard?               // optional "nothing to show" pre-check
}

/// A pre-open probe: run `probe` at the cwd; if it exits 0 (nothing to show),
/// skip opening the float and surface `toast` instead.
struct EmptyGuard: Equatable { let probe: String; let toast: ToastContent }
```

```swift
enum ToolFloatCatalog {
    static let all: [ToolFloat] = [
        ToolFloat(
            id: "diffnav", title: "Open Diff Nav", shortcut: "⌘⇧G",
            icon: "plus.forwardslash.minus", command: "git diff main",
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: true,
            emptyGuard: EmptyGuard(
                probe: "git diff main --quiet",   // exit 0 ⇒ no changes
                toast: ToastContent(
                    symbol: "checkmark.circle.fill", title: "No changes vs main",
                    message: "Your branch matches main — nothing to diff."))),
    ]
    static func byID(_ id: String) -> ToolFloat? { all.first { $0.id == id } }
}
```

## The engine (on `TabController`)

One live slot (tool floats are modal / mutually exclusive), so no per-tool fields:

```swift
private var activeToolFloat: (spec: ToolFloat, surface: TerminalSurface, overlay: SurfaceFloatOverlay)?
var activeToolFloatID: String? { activeToolFloat?.spec.id }
var isToolFloatOpen: Bool { activeToolFloat != nil }
```

- **`toggleToolFloat(_ spec:)`** — if the same id is open → `closeToolFloat()`.
  Otherwise: close any current float, run the guards, then open.
  - **git-repo guard:** `requiresGitRepo` && `gitRepoRoot(for: focusedCWD) == nil`
    → `onRequestToast(notARepoToast)`, return. (Reuses the lazygit guard +
    ZEN-48 toast infra.)
  - **empty guard:** if `emptyGuard` and the probe (run at `focusedCWD`) exits 0
    → `onRequestToast(spec.emptyGuard.toast)`, return.
  - **open:** `exitZoomIfNeeded()`, spawn a fresh `TerminalSurface`
    (`$SHELL -l -i -c command`, `workingDirectory: focusedCWD`), present a
    `SurfaceFloatOverlay(content:… widthFraction: spec.widthFraction,
    heightFraction: spec.heightFraction, contentInset: 10, cornerRadius: 14,
    onDismiss: closeToolFloat)` via `presentTileOverlay`, clear pane/drawer halos,
    `surface.focus()`, `animateIn()`, `onOverlayStateChanged()`.
- **`closeToolFloat()`** — `overlay.animateOut { removeFromSuperview }`,
  `surface.terminate()`, clear the slot, `restoreUnifiedFocus()`,
  `onOverlayStateChanged()`. (Terminate, not hide — ephemeral.)
- **`surfaceDidExit`** branch: `s === activeToolFloat?.surface` → same teardown
  (this is how `q` inside diffnav closes the float).
- **`shutdown()`** — animate-less remove + terminate the active tool float.

Reuses the existing `gitRepoRoot(for:)`, `onRequestToast`, `presentTileOverlay`,
`restoreUnifiedFocus`, `exitZoomIfNeeded`, and the `SurfaceFloatOverlay` base — so
the engine is genuinely small.

**Empty-guard probe execution & cost:** run the probe as a short synchronous
`Process` — `$SHELL -c "<probe>"` (plain, **non-login/non-interactive** so it
doesn't re-source rc files) with `currentDirectoryURL = focusedCWD` — and read
its exit status (0 ⇒ empty). `git diff main --quiet` returns at the first hunk, so
it's fast. Only floats that declare an `emptyGuard` pay it, and only on the toggle
that opens them.

## Keybinding & dispatch

`KeyInterceptor.ReservedChord` gains one generalized case:

```swift
case toggleToolFloat(String)   // associated value = ToolFloat.id
```

In the `[.command, .shift]` branch, the free `"g"` maps to it:

```swift
case "g": chord = .toggleToolFloat("diffnav")
```

`WindowController.handle` dispatches generically:

```swift
case .toggleToolFloat(let id):
    if let spec = ToolFloatCatalog.byID(id) { active?.toggleToolFloat(spec) }
```

## Modal gate (mirrors lazygit)

`WindowController.handle` gets a tool-float gate alongside the lazygit one: while
`active?.isToolFloatOpen == true`, only closing + cross-tab/window chords act.
Because the lazygit gate runs first and doesn't allow `.toggleToolFloat`, and this
gate doesn't allow `.toggleLazygit`, the two float families are **mutually
exclusive** — same modal behavior the palettes already have.

```swift
if active?.isToolFloatOpen == true {
    switch chord {
    case .closePane: active?.closeToolFloat(); return          // ⌘W closes
    case .toggleToolFloat, .newTab, .newWindow, .selectTab, .prevTab, .nextTab: break
    default: return
    }
}
```

## Dock & palette (auto-derived from the catalog)

- **`ToggleDock`** takes `toolFloats: [ToolFloat]` + `onToolFloat: (ToolFloat) ->
  Void`, renders one `IconButton(symbol: spec.icon)` per spec **after** the
  lazygit button, and keeps an `[id: IconButton]` map. `render(overlay:)` lights
  the button whose id == `overlay.activeToolFloatID`. `OverlayState` gains
  `activeToolFloatID: String?`.
- **`CommandCatalog`** — `spec(for: .toggleToolFloat(id))` looks the title/shortcut
  up from `ToolFloatCatalog.byID(id)`; `commands(tabCount:)` appends a
  `.toggleToolFloat(spec.id)` for each catalog entry in the Tools group (next to
  lazygit). The switch stays exhaustive (compile-enforced).

## The repeatable recipe (what "add a float" costs)

1. Append a `ToolFloat` to `ToolFloatCatalog.all`.
2. Add one line in `KeyInterceptor` mapping a chord to `.toggleToolFloat("<id>")`.

That's it — the dock button, palette entry, git guard, empty guard, spawn/present/
dismiss, modal gate, and active-state tint all derive from the spec. **Explicit
non-goal (flagged for later):** fully *user-configurable* N floats need runtime
keybinding config (chords are compile-time in `KeyInterceptor`) and a user config
source for the catalog — a follow-up ticket, not this one.

## Scope notes

- **Base branch** hardcoded to `main` per the ticket. A repo without `main`
  surfaces git's own error inside the float — acceptable v1; a base-branch
  fallback is a later refinement.
- **Lazygit is untouched** — no regression to ZEN-48. `LazygitOverlay` stays; the
  engine instantiates `SurfaceFloatOverlay` directly (no per-float overlay
  subclass needed).

## Testing

- **Unit:** `ToolFloatCatalog` shape (ids unique, diffnav present) is trivially
  assertable; `CommandCatalog` exhaustiveness stays compile-enforced. No
  meaningful unit surface for the AppKit engine (shell-out + overlay).
- **Manual runbook:** `⌘⇧G` opens the 85%×85% float showing `git diff main` via
  diffnav; `q` / `⌘⇧G` / `⌘W` / backdrop-click all close and terminate it;
  reopening reflects fresh edits (spawn-fresh); outside a git repo → "Not a Git
  repository" toast; clean branch vs main → "No changes vs main" toast; the dock
  button (right of lazygit) and the "Open Diff Nav" palette entry both toggle it
  with the active tint; lazygit and DiffNav can't be open at once.

## Ship

`bin/check` green → `/code-review` → triage (no tech debt) → ZEN-36 to In Review.
Branch `feature/zen-36-new-diff-nav-float` off main (no conflicts with the pending
chrome branches).
