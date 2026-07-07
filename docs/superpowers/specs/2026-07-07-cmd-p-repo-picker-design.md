# ⌘P Repo Picker + Pinned Tab Names

**Status:** approved 2026-07-07. Replaces the dropped `⌘E` global sidebar (Epic 3 PR5).

## Goal

A window-level `⌘P` command palette to jump to a project in `~/dev`. Fully
keyboard-driven — no mouse required. Selecting opens the directory as a shell
session, either in a new tab (`Enter`) or by replacing the current tab
(`Shift+Enter`). Either way the tab gets a **pinned** name (the directory
basename) that never changes as the focused pane's cwd moves.

## Behavior

### Trigger & modality
- `⌘P` (bare command) opens a centered modal palette over the active tab of the
  key window. `⌘P` again closes it.
- Presented in the **same overlay family as the lazygit float**: a tile-scoped
  (pinned to the tab's `content` region), rounded, dim backdrop with a centered
  card — so it never bleeds over the window gutters or tab bar.
- **Mutually exclusive with the lazygit float.** `⌘P` is blocked while the float
  is open (the existing modal gate in `WindowController.handle` swallows it), and
  while the picker is open it is itself modal (all chrome chords swallowed except
  `⌘P`, which closes it) — so `⌘G` can't open under it either.

### Discovery
- Immediate subdirectories of `~/dev` (resolved from the user's home; the macOS
  filesystem is case-insensitive, so `dev` matches `Dev`). Alphabetical.
- A directory containing a `.git` entry is flagged with a small glyph (`⑂`). The
  flag is display-only; **all** directories are listed regardless.
- Scanned fresh each time the picker opens (cheap; no caching in v1).
- If `~/dev` is missing or empty, the palette shows an empty state ("No
  directories in ~/dev") and only `Esc`/`⌘P` do anything.

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

### Workspace preset (on repo open)

Both open paths (new tab and replace) build a project workspace, not a bare shell:
- **Primary pane →** `nvim` (bare — the cwd is already the repo, so it opens the normal
  dashboard, not the directory explorer).
- **Right drawer →** `claude`, auto-revealed.
- **Bottom drawer →** a plain shell, auto-revealed.
- Focus lands on the primary (nvim) pane.

`nvim` and `claude` launch via a **program-then-shell** recipe (`ShellLaunch.program`):
`$SHELL -l -i -c "<program>; exec $SHELL -l -i"`. Quitting the program (`:q`, `Ctrl-D`)
drops back to a login+interactive prompt in the same pane/drawer instead of closing it —
essential for the primary pane, since a bare `nvim` process exiting would otherwise close
the last pane and the whole tab. The preset is **hardcoded** (nvim/claude/shell) for v1;
configurability is future work. Plain tabs (`⌘t`, first tab) are unaffected — plain shell.

### Bundled tweak: shortcut swap

`⌘\` and `⌘⇧\` (`⌘|`) are swapped: **`⌘\` → toggle right drawer**, **`⌘⇧\` → vertical
split** (previously the reverse).

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
  `⌘P`; while any tab `isLazygitOpen`, `⌘P` is already swallowed.
- **`KeyInterceptor`** — add `case toggleRepoPicker` to `ReservedChord` and
  `case "p": chord = .toggleRepoPicker` in the bare-`⌘` switch. (`⌘K` stays
  pane-nav-up; `⌘P` — the classic project switcher — avoids the clash.)

## Testing

- **Unit (`RepoScanner`):** against a temp tree — lists only immediate
  subdirectories, ignores files, sets `isGitRepo` from a `.git` child, sorts
  alphabetically, empty root → empty list.
- **Manual runbook:**
  1. `⌘P` → palette opens centered over the tab; typing filters; `↑/↓` moves the
     iris selection; footer hints show.
  2. `Enter` on a repo → new tab in that dir; tab name = dir basename; `cd`
     elsewhere in the pane → tab name stays pinned.
  3. `Shift+Enter` → current tab is replaced by a fresh session in the dir, pinned
     name; old panes gone.
  4. `Esc` / `⌘P` → closes with no action.
  5. `⌘P` does nothing while a lazygit float is open; `⌘G` does nothing while the
     picker is open.
  6. Git repos show `⑂`; plain dirs don't; both are selectable.

## Out of scope (v1)

Fuzzy matching, configurable/multiple scan roots, recursive discovery, recent/
frecency ordering, and creating a directory from the palette. `~/dev` is the
hardcoded root.
