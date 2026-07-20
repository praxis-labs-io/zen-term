# Spike: parallel multi-agent lanes via APFS clones + conflict radar

**Status:** investigation / not started. No code yet. Output of this spike is a
go / no-go on the substrate plus a shaped Linear project.

**Branch for pickup:** `claude/zenterm-work-tree-integration-8w481o`

**How to use this doc:** it is scratch, per the repo rule that a spec lives in
`docs/` only while the work is in flight. When the epic ships, fold anything
architectural into `docs/architecture.md` and delete this file. Until then it is
the brief: a fresh session should be able to read this top to bottom and start
without the originating chat.

---

## 1. The problem and the bet

Let a person run several agent sessions against one project at once, each on its
own branch, isolated so they do not step on each other, with a way to see them
all, switch between them, and land or discard each. Then get ahead of the merge
pain that parallel work creates.

The bet has two independent pieces:

1. **Substrate:** isolate each agent's working tree with an **APFS copy-on-write
   clone** of the repo, not a `git worktree`. The clone carries the built
   artifacts, so an agent starts in a tree that already compiles.
2. **Orchestration + radar:** a board that shows the lanes and their live status,
   and a **conflict radar** that speculatively trial-merges lanes (against
   mainline and against each other) so collisions surface before you promote,
   not at merge time.

Only the orchestration layer is the durable product. The substrate is a
swappable backend behind a thin seam (APFS first, `git worktree` as fallback).

---

## 2. Glossary (working names, not final)

- **lane** — one isolated, branch-bound instance of a project an agent works in.
  Vocabulary not settled; "workspace" is already taken (see open questions).
- **mainline** — the origin checkout the lanes were cloned from.
- **promote** — land a lane's branch back into mainline.
- **reap** — delete a lane's clone once its work is landed or abandoned.
- **radar** — the background trial-merge engine that reports per-lane and
  cross-lane conflict status.

---

## 3. Codebase orientation (read these before starting)

zen-term is chrome around ghostty; the terminal is a drop-in behind the
`TerminalSurface` seam. This feature is **entirely above the seam** — it touches
no backend and does not `import GhosttyKit`. It is a new pure helper plus chrome.

Files a fresh session should read first:

- `docs/architecture.md` — the one architecture doc. The seam, the pane tree,
  tabs/windows, the modal slot, config.
- `Sources/ZenTerm/GitRepo.swift` — the existing pure git helper. The new `Lane`
  helper sits next to it and follows its shape (pure, off-main callers, no
  AppKit). Note it already knows a `.git` **file** means a worktree/submodule.
- `Sources/ZenTerm/Workspace.swift` — a workspace is a named path + a recipe
  (`main` / `right` / `bottom` commands, `env`, `focus`). A lane reuses this
  recipe pointed at the lane's cwd. Nothing new is needed to open a lane's panes.
- `Sources/ZenTerm/RepoPickerOverlay.swift` — the `⌘⇧P` workspace picker, built
  on `PaletteOverlay`. `onChoose(Workspace, replaceCurrentTab)` opens a workspace
  in a new tab (or replaces the current one). The lane board is a sibling of this
  overlay, or an extension of it.
- `Sources/ZenTerm/PaletteOverlay.swift`, `ModalCard.swift`,
  `CommandPaletteOverlay.swift`, `CommandCatalog.swift` — the card / list /
  keyboard scaffolding a board would reuse.
- `Sources/ZenTerm/WindowController.swift` — owns the window, the `TabList`, and
  the single modal slot. `ModalKind` (around line 91) is
  `repoPicker, commandPalette, workspaceForm, settings, toolFloatForm`; a lane
  board adds a case here. New-tab / open-workspace flow lives here.
- `Sources/ZenTerm/TabController.swift` — owns one tab: a `PaneCanvasController`
  plus the two drawers. An agent lane is a tab whose `main`/`right` recipe runs
  the agent (for example `right = claude`), cwd = the lane path. `isBusy` per
  surface (OSC 133 prompt marks) is the raw signal for agent "running vs waiting."

Load-bearing rules this feature must respect (from `CLAUDE.md` and
`docs/architecture.md`):

- **Never block the main thread.** Every `cp`, `git`, and `rm` is a subprocess;
  run it off-main and hop back for the UI update (ZEN-90).
- **The seam does not move.** Anything only git/APFS can do stays in the `Lane`
  helper, not in the chrome's general vocabulary.
- **Colors are theme-driven**, copy follows `docs/brand-voice.md` (no em-dashes,
  no hype words, confirmations state the consequence and never ask "Are you
  sure?"). One word per concept: pick the lane vocabulary and hold it.
- **No `TODO`/`FIXME`.** Residual work is a Linear ticket.

---

## 4. Substrate: APFS clones

### Mechanism

APFS is copy-on-write: a file is a set of extents (block ranges) referenced
through metadata. `clonefile(2)` (reachable via `cp -Rc src dst`, the same
syscall Finder "Duplicate" uses) makes a new file that points at the same extents
and bumps their refcount. Consequences:

- **Instant.** Cost scales with file count (the directory walk), not bytes.
  Cloning a multi-GB `.build` is as cheap as cloning a small file.
- **Near-zero disk until write.** Clone and origin share physical blocks; a write
  allocates a fresh block for just that block and repoints one side. Divergence
  cost is exactly the delta, block-granular.
- **Safe delete.** `rm -rf` decrements refcounts; only diverged blocks are freed.
- **Same-volume only.** Extents are volume-local. Cross-volume, `clonefile` fails
  and `cp -c` falls back to a full byte copy **silently**. The lanes dir must be
  on the repo's volume or the whole premise evaporates without an error.

### Why APFS over `git worktree` here

A `cp -Rc <repo> <lane>` clone carries everything, including untracked and
gitignored files:

- `.build/` fully populated (warm build cache)
- `Frameworks/GhosttyKit.xcframework` (gitignored, built per machine)
- the `Sources/TerminalKit/Resources/ghostty-resources` symlink
- untracked local files (`.env`, local config)

A fresh `git worktree` has none of that: tracked files only, empty `.build`, no
GhosttyKit, so its first build is a cold compile **plus** `bin/build-ghosttykit`
setup. The clone's floor is therefore no worse than a worktree, and its ceiling
(if the build cache survives relocation, see risk in section 9) is much better.

### The tradeoff: a clone is a standalone repo

`switch -c` gives each lane an independent git history. The clone does **not**
appear in origin's `git worktree list` or `git branch`. So you lose worktree's
free rediscovery. Get it back with a **convention, not a filesystem scan**: put
lanes in one known, bounded directory and enumerate only that. That is reading
your own state dir (same category as a build dir), not scanning the user's
projects, so it stays true to "zen-term does not scan directories."

### Layout

Lanes live in a hidden dir **sibling to the repo**, namespaced by repo:

```
<repo>/../.zenlanes/<repo-name>/<lane>/
```

- Sibling keeps it on the repo's volume (same parent dir), so `clonefile` stays
  real CoW.
- Sibling, not nested inside the repo tree: a clone-with-its-own-`.git` under the
  parent repo confuses `GitRepo.repoRoot` walks and the parent's `git status`.

---

## 5. The `Lane` helper (API sketch)

Pure, no AppKit, all subprocess work off-main. Sits next to `GitRepo.swift`.

```swift
struct Lane {
    let name: String
    let path: URL          // the clone
    let branch: String
    let base: URL          // the mainline repo it was cloned from
}

struct LaneStatus {
    let branch: String
    let ahead: Int
    let behind: Int        // vs mainline
    let dirtyCount: Int    // uncommitted changes
    let ready: Bool
}

enum LaneBackend { case apfsClone, worktree }   // #1 with graceful fallback

enum LaneStore {
    // same-volume check -> cp -Rc (or worktree fallback) -> git switch -c
    static func create(from repo: URL, name: String, branch: String) async throws -> Lane
    // enumerate <repo>/../.zenlanes/<repo-name>/
    static func list(for repo: URL) async throws -> [Lane]
    static func status(_ lane: Lane) async throws -> LaneStatus
    // git -C repo fetch <lane.path> <branch>:<branch>, then merge/rebase
    static func promote(_ lane: Lane, into repo: URL, strategy: MergeStrategy) async throws
    // rm -rf lane.path
    static func reap(_ lane: Lane) async throws
}
```

`create` tries `cp -c`; on `ENOTSUP` (non-APFS, cross-volume, network mount) it
falls back to `git worktree add` and flags the lane as non-CoW so the UI can say
so. That fallback is the whole "pluggable backend" story: build APFS, let
worktree be the degradation, do not build a speculative provider abstraction.

Testability: mirror `SeamTests` / `SpySurface`. The helper is pure and
id-driven, so unit tests can drive `create/list/status/reap` against a temp git
repo without any terminal backend.

---

## 6. Orchestration: the board

A lane maps onto a **tab** (tabs already retain inactive shells, so N lanes = N
live agents, one mounted). The tab title carries the branch; a glyph marks it as
a lane.

Surfaces to choose between (open question 3 in section 10):

- **Extend `⌘⇧P`** (`RepoPickerOverlay`) into two levels: workspaces, and under
  each, its live lanes + a "＋ New lane" row. Least new surface area.
- **A new modal card**: add `case laneBoard` to `ModalKind` and build a
  `LaneBoardOverlay` on `PaletteOverlay`, sibling to the command palette.
- **A persistent dock/rail** listing lanes with live status. Heaviest; a v2.

Per-lane row shows: branch, ahead/behind, dirty count, **agent state**
(running / waiting on you / idle), and **radar state** (section 7). Agent state
derives from per-surface `isBusy` (OSC 133): busy = agent working, not-busy at a
prompt = waiting on you. That turns "6 terminals to babysit" into "3 working, 1
needs you, 1 ready."

Creating a lane: "New lane from this repo" -> prompt a branch name -> off-main
`create` -> open a tab with the workspace recipe pointed at the lane cwd.

---

## 7. Conflict radar

Lane merges are ordinary git three-way merges (identical to two devs' PRs). What
changes with parallel agents:

- **More conflicts**, because several branches land into one mainline in quick
  succession and each lane is frozen at its clone-time base until you promote.
- **More semantic conflicts git cannot see:** agent A renames a symbol, agent B
  in another file calls the old name. Textually clean, build broken. Agents
  amplify this because each lane is blind to the others until promote, and there
  is no human "I'm refactoring X, hold off" back-channel.

Because clones are near-free, the board can get ahead of it. The radar runs
**off-main, throttled**, in throwaway CoW clones:

1. **Lane vs mainline.** Trial-merge each lane against current mainline in a
   throwaway clone; report `clean` / `conflicts` per lane.
2. **Lane vs lane.** Trial-merge lanes pairwise to flag pairs that will collide
   while both agents are still running (for example "B and D both touch
   `AuthService.swift`").
3. **Pre-merge build/test.** For a textually-clean merge, run `swift build` (and
   optionally tests) in the throwaway clone to catch the semantic class git is
   blind to. Affordable only because the clone costs nothing.
4. **Merge-order guidance.** From the overlap graph, suggest an integration order
   that minimizes pain (independent lanes first, mutually-overlapping ones last).

Radar states per lane, shown on the board: `clean` / `conflicts with mainline` /
`conflicts with <lane>` / `builds` / `build breaks after merge`. Recompute on
lane commit and on mainline change, debounced. This "conflict radar" is the
strongest single reason to build the feature rather than tell people to run
`git worktree` by hand.

---

## 8. Promote and reap

- **Promote:** `git -C <repo> fetch <lane.path> <branch>:<branch>` over local
  transport (cheap, shared objects), then merge or rebase. Offer the radar's
  recommended order.
- **Reap:** `rm -rf <lane.path>`. Instant; CoW frees only diverged blocks. No
  `git worktree remove --force`, no `.git/worktrees` bookkeeping.
- **Confirms** state the consequence, never ask "Are you sure?" (brand voice):
  for example "Reap lane <name>: 3 uncommitted files, agent still running."

---

## 9. Risks and footguns

- **SwiftPM path invalidation (the go/no-go).** llbuild keys its incremental
  graph on absolute paths (build db, module cache, DWARF). A clone at a new path
  may invalidate and rebuild cold, erasing the ceiling. Mitigations: measure
  first (section 11); keep a lane's path stable after creation so only the first
  build is cold; even cold, the clone still wins on setup (GhosttyKit + symlinks
  present) over a worktree. **Settle this before any design work.**
- **Same-volume or bust.** Verify volume ids up front and warn loudly, or
  `clonefile` silently degrades to a full copy.
- **Runtime is not isolated.** APFS isolates files + build artifacts, not ports /
  DB / services. Two lanes running `npm run dev` still collide. Env-templated
  ports or containers are a separate axis (open question 2).
- **Secrets ride along.** Untracked `.env` is cloned into every lane. Fine on one
  machine, but a conscious yes.
- **`du` lies.** CoW-shared blocks are counted per file, so lanes look huge while
  costing almost nothing. Do not surface a size number.
- **Main thread.** All `cp`/`git`/`rm`/build off-main (ZEN-90).
- **GhosttyKit per lane.** Present via the clone, but if a lane's build
  regenerates resources, make sure it does not clobber the origin's symlink
  target.

---

## 10. Open questions (resolve in this spike)

1. **Go / no-go:** does a relocated `.build/` give an incremental (not cold)
   `swift build`? (Benchmark in section 11.)
2. **Files or environments?** Is runtime isolation (ports / DB / services) in
   scope, or explicitly out for v1?
3. **Live-in vs review-and-reap?** Is a lane a place you work, or a proposed
   change (diff vs mainline) you accept / discard? Changes whether the board
   centers on terminals or diffs.
4. **Vocabulary:** lane / branch / worktree / feature. One word, hold it.
5. **Discovery:** lanes-dir convention vs a registry file.
6. **Board surface:** extend `⌘⇧P`, new modal card, or persistent dock.
7. **Same-volume fallback behavior** when `clonefile` is unavailable: worktree,
   plain copy, or refuse.

---

## 11. Validation plan (do this first, on a Mac)

The whole go/no-go is one measurement:

```sh
cd ~/Dev/zen-term && swift build          # warm the origin .build
time cp -Rc . ../zenlane-test             # expect well under a second
cd ../zenlane-test && git switch -c lane-test
time swift build                          # <-- the number that decides it
```

- Incremental second build -> APFS lanes are clearly better than worktrees here;
  build the `Lane` seam around APFS.
- Cold second build -> the clone still wins on setup; decide whether that alone
  beats worktree, and whether to hold a lane's path fixed to pay cold only once.

Also verify: `cp -Rc` across the intended lanes-dir path stays CoW (same volume);
`rm -rf` on a lane frees only diverged blocks; a local `git fetch <lane>` promote
round-trips cleanly.

---

## 12. Proposed decomposition (when this graduates to a Linear project)

Each is PR-sized (1 ticket = 1 branch = 1 PR). Do not create these until the
spike says go; listed here so the shaping is done.

1. **`Lane` helper** — pure, off-main: `create` (APFS clone + worktree fallback),
   `list`, `status`, `reap`. Unit-tested against a temp repo. No UI.
2. **New-lane command + lane tab** — command to create a lane and open it in a
   tab running the workspace recipe at the lane cwd; branch in the tab title.
3. **Lane board** — the switcher surface (decided in Q6), listing lanes with
   branch / ahead-behind / dirty.
4. **Live agent status** — wire per-surface `isBusy` into the board
   (running / waiting / idle).
5. **Radar engine** — off-main trial-merge (lane vs mainline, lane vs lane) with
   throttling; board conflict states.
6. **Pre-merge build/test** — extend the radar to build/test the trial-merge and
   report the semantic-conflict class.
7. **Promote / reap flows** — fetch-and-merge promote, `rm -rf` reap, consequence
   confirms, merge-order suggestion.

Config / vocabulary decisions (Q2, Q4, Q5) fold into tickets 1-3.

---

## 13. Starting a fresh session on this

1. Check out `claude/zenterm-work-tree-integration-8w481o` and read this file,
   then `docs/architecture.md`, then the files in section 3.
2. Run the section 11 benchmark on a Mac. Record the number; it sets the
   framing for everything.
3. Answer as many open questions (section 10) as the benchmark and a short design
   pass allow.
4. If go: create the Linear **project** and its first PR-sized ticket
   (section 12, ticket 1). Do not dump the whole backlog up front.
5. Keep this doc updated while in flight; delete it and fold the architecture
   into `docs/architecture.md` when the epic ships.
