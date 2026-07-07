# ⌘K Repo Picker + Pinned Tab Names

**Status:** approved 2026-07-07. Replaces the dropped `⌘E` global sidebar (Epic 3 PR5).

## Goal

A window-level `⌘K` command palette to jump to a project in `~/dev`. Fully
keyboard-driven — no mouse required. Selecting opens the directory as a shell
session, either in a new tab (`Enter`) or by replacing the current tab
(`Shift+Enter`). Either way the tab gets a **pinned** name (the directory
basename) that never changes as the focused pane's cwd moves.

## Behavior

### Trigger & modality
- `⌘K` (bare command) opens a centered modal palette over the active tab of the
  key window. `⌘K` again closes it.
- Presented in the **same overlay family as the lazygit float**: a tile-scoped
  (pinned to the tab's `content` region), rounded, dim backdrop with a centered
  card — so it never bleeds over the window gutters or tab bar.
- **Mutually exclusive with the lazygit float.** `⌘K` is blocked while the float
  is open (the existing modal gate in `WindowController.handle` swallows it), and
  while the picker is open it is itself modal (all chrome chords swallowed except
  `⌘K`, which closes it) — so `⌘G` can't open under it either.

### Discovery
- Immediate subdirectories of `~/dev` (resolved from the user's home; the macOS
  filesystem is case-insensitive, so `dev` matches `Dev`). Alphabetical.
- A directory containing a `.git` entry is flagged with a small glyph (`⑂`). The
  flag is display-only; **all** directories are listed regardless.
- Scanned fresh each time the picker opens (cheap; no caching in v1).
- If `~/dev` is missing or empty, the palette shows an empty state ("No
  directories in ~/dev") and only `Esc`/`⌘K` do anything.

### Palette UI
- A search field (auto-focused first responder) on top; a scrollable result list
  below; a hint footer (`↵ new tab   ⇧↵ replace   ↑↓ move   esc close`).
- The selected row uses the iris accent; the git flag glyph is muted trailing.

### Keyboard (complete — no mouse needed)
- **Type** → filter. Case-insensitive **substring** match; rows whose name
  *starts with* the query rank above interior matches, then alphabetical.
- **↑ / ↓** → move the selection; clamps at first/last (no wrap).
- **Enter** → open the selected directory in a **new tab**.
- **Shift+Enter** → **replace the current tab**: tear it down and start a fresh
  single-pane session in the selected directory.
- **Esc** → close the picker, no action.
- The selection resets to the top row whenever the filter changes.
- Clicking a row selects it and clicking again (or Enter) opens it — a bonus;
  every action is reachable from the keyboard.

### Pinned tab name
- Both open paths set the new/replaced tab's name to the selected directory's
  basename and **pin** it.
- Pinning is a per-tab override on the title source: `TabController` gains
  `pinnedTitle: String?`, and `title` returns `pinnedTitle ?? paneCanvas.title`.
  The window's cwd-title poll compares `TabController.title` and therefore sees a
  stable value — no change to the poll needed. Tabs opened any other way (default
  `⌘t`, `⌘n`) have `pinnedTitle == nil` and keep live-cwd titles.

## Architecture

New and changed units (chrome only — nothing crosses the `TerminalSurface` seam;
the picker just spawns ordinary shell sessions via the existing tab machinery):

- **`RepoScanner`** (new, `Sources/ZenTerm/RepoScanner.swift`) — pure helper.
  `static func scan(root: URL) -> [RepoEntry]` returning `RepoEntry { url: URL,
  name: String, isGitRepo: Bool }`, sorted alphabetically. Unit-testable against
  a temp directory tree.
- **`RepoPickerOverlay`** (new, `Sources/ZenTerm/RepoPickerOverlay.swift`) — the
  palette view (search field + list + footer), owns filter + selection + keyboard
  handling, and emits `onChoose(URL, replaceCurrentTab: Bool)` and `onDismiss()`.
  Reuses the overlay chrome idiom from `LazygitOverlay` (tile-scoped rounded dim
  backdrop, centered card).
- **`TabController`** — add `var pinnedTitle: String?`; `title` returns
  `pinnedTitle ?? paneCanvas.title`.
- **`WindowController`** — own the picker lifecycle: `toggleRepoPicker()` presents
  or dismisses it in `content` of the active tab; `isRepoPickerOpen`. On choose:
  - new tab → the existing `newTab` path, but with `initialCWD = dir` and
    `pinnedTitle = dir.lastPathComponent`.
  - replace → swap the active tab id's `TabController` for a fresh one
    (`initialCWD = dir`, pinned title), `shutdown()` the old one, remount.
  Extend the modal gate: while `isRepoPickerOpen`, swallow all chords except
  `⌘K`; while any tab `isLazygitOpen`, `⌘K` is already swallowed.
- **`KeyInterceptor`** — add `case toggleRepoPicker` to `ReservedChord` and
  `case "k": chord = .toggleRepoPicker` in the bare-`⌘` switch.

## Testing

- **Unit (`RepoScanner`):** against a temp tree — lists only immediate
  subdirectories, ignores files, sets `isGitRepo` from a `.git` child, sorts
  alphabetically, empty root → empty list.
- **Manual runbook:**
  1. `⌘K` → palette opens centered over the tab; typing filters; `↑/↓` moves the
     iris selection; footer hints show.
  2. `Enter` on a repo → new tab in that dir; tab name = dir basename; `cd`
     elsewhere in the pane → tab name stays pinned.
  3. `Shift+Enter` → current tab is replaced by a fresh session in the dir, pinned
     name; old panes gone.
  4. `Esc` / `⌘K` → closes with no action.
  5. `⌘K` does nothing while a lazygit float is open; `⌘G` does nothing while the
     picker is open.
  6. Git repos show `⑂`; plain dirs don't; both are selectable.

## Out of scope (v1)

Fuzzy matching, configurable/multiple scan roots, recursive discovery, recent/
frecency ordering, and creating a directory from the palette. `~/dev` is the
hardcoded root.
