# Diff viewer → full code review

> **Purpose and status.** This is a scratch spec, not a doc that describes what is
> true today. It exists to scaffold the Linear epic and write the tickets from, then
> to hand implementation to a future (non-sandboxed) session. No code is written in
> this session; the next session's first job is the **Linear scaffolding** section
> at the end.
>
> **Why this is committed, given CLAUDE.md says a spec is never committed.** A spec
> normally lives uncommitted in `docs/` while an epic is in flight. This one is
> committed to its feature branch as a **deliberate, temporary exception**: the
> planning ran in an ephemeral remote container whose working tree does not survive
> to a fresh session, and git is the only channel that carries it across. It is
> committed to the feature branch only, never merged to the default branch, and is
> **deleted once the tickets and the code exist** (fold anything architectural into
> `docs/architecture.md` at that point). Treat its presence on `main` as a mistake.

## Context

The diff viewer is solid: a modal card over the focused tile that stacks a repo's
Unstaged/Staged/Committed slices, renders side-by-side or inline, and lets you
select linewise and turn a selection into a `@path:42-44 note` that gets pasted
into a terminal pane running an agent. Everything is wired through injected
closures in `WindowController.presentDiffViewer` (`loader`, `headsLoader`,
`sendTargets`, `sender`), so the chrome never touches `Process`.

What it is not yet is a place you *review* from. A "comment" today is ephemeral:
`DiffComment.message(...)` builds a string, pastes it, and is discarded. The
"queue" is literally the agent's terminal input buffer with several lines stacked
in it. Nothing is marked reviewed, nothing persists, nothing knows about GitHub,
and the only targets are local branches and worktrees.

This turns the viewer into a real code-review surface: durable comments,
mark-as-reviewed, request-changes, review state that survives between opens for a
branch, PR-based targets, reading and writing GitHub reviewer comments, and a
local agent that consumes the whole accumulated review. The immediate
paste-to-agent path stays first-class, because reviewing code an agent just wrote
(pre-PR, in flight) and firing a correction at it on the spot is a core workflow,
not a fallback.

## Capabilities and where each lands

| Capability | Phase |
|---|---|
| Mark files as reviewed | 1 |
| Persistent comments | 1 |
| Request changes per selection (extends the comment workflow) | 1 |
| Local agent consumes the whole review (extends the queue) | 1 |
| Keep comments local **or** push to GitHub | 3 |
| Review reviewer comments from GitHub | 2 |
| PR-based targets beyond branch/base | 2 |
| Persistence between opens for a branch | 1 |
| Comment threads + replies + emoji (nice-to-have) | 3 |

## Decisions locked (from this session)

- **GitHub via `gh` CLI now, behind a protocol seam** (`GitHubReviewSource`) so a
  native REST/GraphQL client can replace it later without touching call sites.
- **Persist first, then act.** A comment becomes a durable object on save;
  "send to agent" and "post to GitHub" are actions *over* the stored review.
  Immediate invocation stays first-class: Submit/Queue still fire at the agent now
  *and* persist.
- **Local foundation ships first.** Phase 1 is fully useful with zero GitHub
  dependency.

## Architecture

### Store concurrency and ownership (the foundation)

`ReviewStore` is a **plain `final class`** shaped like `GitDiffRunner`: in-memory
state read/mutated only on the main thread (AppKit event handlers, the overlay),
persistence on a private serial `DispatchQueue` with main-hop completions. **Not
an actor, not `@MainActor`** — the tree has zero actors and zero async/await in the
chrome, every `NSTableViewDataSource` read must be a synchronous in-memory lookup
(like `DiffHighlightStore.cached`), and introducing the first actor next to the
Carbon/main-thread enforcement (`docs/swift-conventions.md`, "Carbon and the main
thread") would reopen exactly the isolation-erasure traps that section documents.

- **Ownership is process-level per repo root**, not per tab. `DiffViewerSession`
  is deliberately per-tab and in-memory (`DiffViewerSession.swift`); review state
  must be shared so two tabs on the same repo see the same comments and marks.
  A small registry `[URL: ReviewStore]` keyed by the `repoRoot` `GitDiffRunner`
  already resolves hands back the same instance on reopen, the same shape
  `presentDiffViewer` uses for `tab.diffViewerSession` but keyed process-wide.
  `DiffViewerSession` gains a *reference* to the store, exactly as it already
  references the shared `DiffHighlightStore`.
- **Persistence is whole-state, per branch.** Each save serializes the full
  in-memory model to `~/Library/Application Support/ZenTerm/reviews/<repoID>/<branch>.json`
  via `Data.write(to:options:.atomic)` (temp-then-rename). No read-modify-write:
  the in-memory model is always the newer state, which removes the concurrent-file
  race entirely. Read the file once at store construction, off-main, mirroring
  `ConfigLoader.loadWorkspaces(configRoot:completion:)`. Create the directory with
  `createDirectory(withIntermediateDirectories: true)` like `WorkspacesWriter`.
- **Saves coalesce through the existing `TrailingDebouncer`** (`RepoWatcher.swift`),
  not a hand-rolled `DispatchWorkItem` dance. `signal()` is called from main (the
  debounce timer lives on main, keeping its generation counter thread-confined
  without a lock); only the fired action hops to the I/O queue and encodes a
  **value snapshot** captured at schedule time (never `self`, never `Theme.current`
  or `GeneralConfig.current` or any AppKit call — a one-line comment must say so,
  because this is the `DispatchWorkItem`-invisible-to-the-checker shape the codebase
  was bitten by once).
- **Never throw to the caller on I/O failure.** Match `ConfigLoader`'s
  log-and-fall-back ethos: a failed write means the (already-rendering) in-memory
  state won't survive relaunch; `Log.warning` and move on. A synced/redirected
  `~/Library/Application Support` must never take the app down.

### Data model — `ReviewModel.swift` (pure, Codable, no AppKit)

A versioned envelope, hand-rolled tolerant decoding for enums (modeled on
`NavCommand.decode`, not synthesized `Codable`, so a comment kind written by a
newer build doesn't fail the whole document on downgrade), ISO8601 dates.

- `ReviewDocument { schemaVersion: Int; state: ReviewState }` — decode peeks the
  version first and degrades to an empty state rather than throwing on an
  unknown version.
- `ReviewComment { id: UUID; filePath; scope: DiffScope; anchor: CommentAnchor;
  body; kind: .comment/.changeRequest; origin: .local/.agent/.github/.unknown;
  createdAt; updatedAt; github: GitHubLink?; replies: [ReviewReply];
  reactions: [Reaction] }`.
- `FileReviewState { path; reviewed: Bool; reviewedAtHeadSHA: String? }` — a new
  commit touching the file clears the mark, the way GitHub clears "viewed".
- `ReviewState { repoID; comments; files; updatedAt }`; roll-ups (`openCount`,
  `changeRequestCount`, `isReviewed(path)`) drive the footer and tree.
- `DiffScope` and `ChangeKind` gain `Codable` (simple additions).
- **Enums decode with an `.unknown` fallback** (`origin`, `kind`) so one drifted
  field can't lose every comment in the document.
- **Closures carry a `UUID`, never a comment object or the store** — the
  `DiffSendTarget` discipline ("the chrome never holds the surface itself"). The
  table's decoration closures stay `[weak self]` + id/row lookup.

### Anchoring and staleness — `CommentAnchor.swift` + `AnchorResolver.swift` (pure)

Bare `path:line` is banned here for the reason the codebase already paid for
("A path is not a diff row identity", `docs/swift-conventions.md`): the same path
sits in Unstaged and Staged with different content, and a line number is
meaningless once the diff re-runs against changed content. `CommentAnchor`
distills a `DiffSelection` (`newRange`, `anchorNewLine`, `removedLines`) plus the
evidence to re-find it: a **snapshot of the anchored line text**, a few lines of
`contextBefore`/`contextAfter`, and the `headSHA` the new side was at when authored.

`AnchorResolver.resolve(anchor, newSideLines:currentHeadSHA:) -> ResolvedAnchor`
is pure (the caller supplies current new-side content from
`GitDiffRunner.blobText(for:side:.new)` off-main). The ladder:

1. **SHA match** (committed/PR scope, `anchor.headSHA == currentHeadSHA`): stored
   numbers are exact → `.current`, no content scan. The common reopen case, free.
2. **Content re-location** (SHA moved, or working-tree scope with no stable SHA):
   scan for `snapshot` as a contiguous block; one match → re-anchor
   (`.current`/`.relocated`), several → disambiguate with context then nearest,
   zero → `.outdated`, pinned to the original range clamped to file length and
   badged (greyed, not interleaved) exactly like GitHub greys an outdated thread.
3. **Removals-only** anchors re-locate via the following line's stored text;
   removed text lives in `removedLines` and is never searched for.

This maps one-to-one onto GitHub's model (`start_line`/`line`/`side`/`commit_id`,
`position == null` ⇄ `.outdated`), so the same resolver output later decides
whether a comment posts inline or falls back to a file-level comment.

### GitHub seam — `GitHubReviewSource.swift` + `GHCLIReviewSource.swift`

Protocol below the seam conceptually (a subprocess dependency the chrome shouldn't
construct), injected into the overlay as closures like `Loader`/`Sender`. The
`gh` impl copies `runGit` verbatim: `Process` off-main, **both pipes drained to
EOF before `waitUntilExit`** (stderr on a second queue — `gh api` payloads are
larger than `git diff`, so the deadlock risk is higher), decode on the background
queue, one main hop. `Failure { ghUnavailable; ghError(String); decodingFailed }`
mirrors `GitDiffRunner.Failure` plus a distinct schema-drift case.

Methods → commands: `listPullRequests` (`gh pr list --json …`),
`resolvePullRequest` (`gh pr view <n> --json …`), `pullRequestDiff`
(`gh pr diff <n> --patch` → **reuse `DiffParser.parse`**), `reviewThreads`
(`gh api graphql` over `reviewThreads`), `submitReview`
(`gh api repos/{o}/{r}/pulls/{n}/reviews`), `reply`, `addReaction`. `gh` absent or
unauthenticated fails typed and the PR section simply omits — the graceful-degrade
rule `loadHeads` already uses.

### Integration seam

Everything attaches at `WindowController.presentDiffViewer` (`WindowController.swift`
~1082-1114), which already injects every dependency as a closure. New wiring:
a `ReviewContext { repoID, branchProvider }` + the `ReviewStore` instance, and
(Phase 2+) a `pullRequestLoader` closure and a PR section for `headsLoader`. A PR
pick routes the existing `loader` to a GitHub-backed load that parses `gh pr diff`
into a committed-only `StatusLoad` — the exact shape `head?.hasWorktree == false`
already produces, so render, place-restore, highlight, and single-flight machinery
are untouched.

## Phasing (each ticket = 1 branch = 1 PR)

The epic is a Linear **Project** on the ZenTerm team (create tickets as we go, not
a dumped backlog). Linear MCP is unauthenticated in this session, so tickets get
created when work starts.

### Phase 1 — local foundation (no GitHub)

- **T1 · Review model + store.** `ReviewModel.swift`, `ReviewStore.swift`,
  `ReviewStoreKey.swift`; `Codable` on `DiffScope`/`ChangeKind`; process-level
  registry keyed by `repoRoot`; whole-state atomic save via `TrailingDebouncer`.
  `repoID` from `git config --get remote.origin.url` normalized to
  `host/owner/repo`, falling back to a hash of `repoRoot` (so a moved checkout or
  worktree doesn't orphan the review); `branch` from
  `headOverride?.name ?? currentBranch`, detached → short HEAD SHA. Tests: Codable
  round-trip, unknown-enum tolerance, schema-version mismatch, `repoID` derivation,
  missing-file → empty, injected scratch dir + injected debouncer scheduler.
- **T2 · Anchoring engine.** `CommentAnchor.swift`, `AnchorResolver.swift`. Pure
  tests over hand-built line arrays for all four outcomes and removals-only.
- **T3 · Persist-on-send + request-changes.** `DiffCommentComposer` gains a
  Comment/Request-changes segmented control and a **Save** action beside
  Submit/Queue. `DiffViewerOverlay.openComposer/send` builds a `ReviewComment` from
  the `DiffSelection` + anchor and calls `ReviewStore.addComment` *before* invoking
  `sender` — Submit/Queue still fire at the agent immediately (persistence is
  additive). Adds the `ReviewContext`/store wiring at the one host seam.
- **T4 · Mark-as-reviewed + roll-up.** Toggle `FileReviewState` from the tree
  (`DiffOutlineItem`, `DiffTreeOutlineController`) with a checkmark/greyed row;
  footer shows `n comments · m to review`; un-review on head change via
  `reviewedAtHeadSHA`. New chord gets a runbook line.
- **T5 · Render persisted comments (conservative).** Gutter markers on commented
  new-side lines in `DiffPaneTable`, and **reuse the existing single `composerBox`**
  to view/edit one comment at a time (click a marker → open the box prefilled on
  that line). This deliberately avoids the variable-per-row-height refactor. Extend
  `refreshDecoration()`/`enumerateAvailableRowViews` so a marker change on an
  on-screen row re-stamps immediately; look markers up by row index every
  `viewFor:`. Resolve a file's comments through `AnchorResolver` *inside* the single
  `renderRows` pass (never a second paint — that closes the composer and loses typed
  text).
- **T6 · Send whole review to agent.** `ReviewToAgent.swift` builds one
  consolidated message from all `ReviewState.comments` (each a `DiffReference` +
  body, change-requests flagged), reusing `DiffSendTarget`/`sender`. Footer action
  "Send review". This is the payoff of "persist then act": the agent consumes the
  stored review, not one ephemeral note.

### Phase 2 — GitHub read

- **T7 · GitHub seam + `gh` client** (`GitHubReviewSource`, `GHCLIReviewSource`,
  `GHCLI`): `listPullRequests`/`resolvePullRequest`/`pullRequestDiff` only. Pure
  command-builder + JSON-decode tests against fixtures (like
  `GitDiffRunner.diffArguments`).
- **T8 · PR targets in the head picker.** `DiffTarget { localBranch; pullRequest }`;
  PR section in `headsLoader`; loader routing for `.pullRequest` → committed-only
  `StatusLoad`; review key becomes `pull/<n>`.
- **T9 · Reviewer comments (read-only).** `reviewThreads` → `[ReviewComment(origin:
  .github)]`. **This is the design-pass ticket for the variable-height multi-thread
  inline view** — generalize `DiffPaneTable`'s scalar `composerAnchor`/
  `composerHeight` into a per-row height map with N floating subviews, and revisit
  the half-page / jump-change scroll math, which currently assumes a uniform
  `DiffCellMetrics.rowHeight`. Not a simple `heightOfRow` extension; budget it.

### Phase 3 — GitHub write + threads

- **T10 · Post review** (`submitReview`, event comment/approve/request-changes)
  from stored local comments; per-comment keep-local-vs-push.
- **T11 · Reply to thread** (`reply`), appending a `ReviewReply`.
- **T12 · Reactions/emoji** (`addReaction`).

## Key risks

1. **Variable per-row height (T9).** Persistent inline threads turn "at most one
   grown row" into "an arbitrary subset have per-row heights", which breaks
   `NSTableView`'s height cache and the `centerRow`/`jumpChange`/`halfPage` math.
   Phase 1 sidesteps it by reusing the single box; T9 owns the refactor with its own
   design pass. Candidate new `swift-conventions.md` entry.
2. **Re-anchor without a second paint.** `renderRows` paints exactly once on
   purpose. Comment overlays resolve and install inside that pass; blob content for
   resolution is fetched off-main, never synchronously on main.
3. **Single-flight load × async store load.** The git load is single-flight and the
   `RepoWatcher` fires constantly; `ReviewStore.load` is independent disk I/O. Reuse
   the `pendingCursor` idiom (hold resolved comments by path, apply when that file's
   rows arrive) and re-resolve after each `apply` (working-tree lines drift),
   debounced so an FS burst doesn't thrash the resolver.
4. **Working-tree scopes have no stable SHA**, so unstaged/staged comments only
   content-match and `.relocated`/`.outdated` churn is normal there; only
   committed/PR comments get the cheap SHA-exact path.
5. **`gh` absent/unauthenticated** degrades (omit PR section), never errors the
   viewer.

## Reuse (do not rebuild)

- `GitDiffRunner` subprocess shape (off-main + main-hop, drain both pipes) →
  `ReviewStore` I/O and `GHCLIReviewSource`.
- `TrailingDebouncer` (`RepoWatcher.swift`) → save coalescing, with an injected
  scheduler for tests.
- `ConfigLoader.loadWorkspaces` split-read-from-parse + `defaultRootOverrideForTesting`
  → store load + test dir injection.
- `NavCommand.decode` → tolerant enum decoding.
- `DiffSelection`/`DiffReference`/`DiffParser.parse` → anchors, references, PR diff
  parsing (verbatim).
- `DiffViewerOverlay` `Loader`/`Sender` closure injection + `presentDiffViewer`
  wiring → the review-store and GitHub closures.
- `DiffPaneTable.reservableModifiers` → any new chord's modifier match.

## Critical files

- `Sources/ZenTerm/WindowController.swift` (~1082-1114) — the closure seam; where
  the store and GitHub source get injected.
- `Sources/ZenTerm/DiffViewerOverlay.swift` — `openComposer`, `apply`, `renderRows`,
  single-flight `reload`; persistence, re-anchoring, PR targets.
- `Sources/ZenTerm/DiffPaneTable.swift` — gutter markers (T5) and the
  variable-height thread refactor (T9).
- `Sources/ZenTerm/DiffCommentComposer.swift` — request-changes control + Save.
- `Sources/ZenTerm/DiffViewerSession.swift` — gains a store reference.
- `Sources/ZenTerm/GitDiffRunner.swift`, `RepoWatcher.swift`, `ConfigLoader.swift`,
  `NavCommand.swift` — the patterns copied.
- New: `ReviewModel.swift`, `ReviewStore.swift`, `ReviewStoreKey.swift`,
  `CommentAnchor.swift`, `AnchorResolver.swift`, `ReviewToAgent.swift`,
  `GitHubReviewSource.swift`, `GHCLIReviewSource.swift`, `GHCLI.swift`.

## Docs to update as it ships

- `docs/architecture.md` — the diff-viewer chrome section (the review model, store
  ownership, PR targets) once each phase lands; fold the epic spec in and delete any
  scratch, per CLAUDE.md.
- `docs/swift-conventions.md` — a new entry for the variable-per-row-height
  virtualization shape (T9).
- Copy for any new label/toast/empty-state runs through `docs/brand-voice.md` first
  (no em-dashes, no hype, name the actor; confirmations state the consequence).

## Linear scaffolding

**Done, at the end of the planning session (2026-08-01).** The workspace now holds:

- Project **Diff Viewer: Code Review** on the ZenTerm team, with milestones
  `Local foundation`, `GitHub read`, `GitHub write`.
- Labels `diff-viewer`, `persistence`, `github`.
- Phase 1 tickets, all Backlog, blocked-by relations wired:
  - **ZEN-334** = T1 Review model + persisted store (`zen-334-review-model-persisted-store`)
  - **ZEN-335** = T2 Comment anchoring engine (`zen-335-comment-anchoring-engine`)
  - **ZEN-336** = T4 Mark files as reviewed + review roll-up (`zen-336-mark-files-as-reviewed-review-roll-up`)
  - **ZEN-337** = T3 Persist comments on send + request-changes kind (`zen-337-persist-comments-on-send-request-changes-kind`)
  - **ZEN-338** = T5 Render persisted comments + gutter markers (`zen-338-render-persisted-comments-gutter-markers`)
  - **ZEN-339** = T6 Send whole review to agent (`zen-339-send-whole-review-to-agent`)

**Do not re-create any of these.** What remains for a later session: create the
Phase 2 tickets (T7-T9) when GitHub read starts and Phase 3 (T10-T12) when GitHub
write starts, per the create-as-we-go rule. Address statuses and projects **by
name, never a UUID**. Branch names come from each ticket's `gitBranchName` field
**verbatim** (Phase 1's are listed above). Reference the issue id in commits and
PRs so Linear auto-links.

The conventions and full ticket bodies below remain the source for the Phase 2-3
creations and for implementing Phase 1.

- **Epic = a Linear Project** (an epic is a Project, never a tracking issue). Name
  it e.g. `Diff Viewer: Code Review`. Task tickets belong directly to it.
- **Milestones = the three phases**: `Local foundation`, `GitHub read`,
  `GitHub write`.
- **Every ticket needs a project, a milestone, a priority, a label, and a status.**
  No orphans. Start each at Backlog, move to Todo when picked up, In Progress while
  building. The GitHub integration moves In Review and Done on its own, so do not set
  those by hand.
- **Branch names come from each Linear ticket's `gitBranchName` field, verbatim** —
  do not invent them from the `Tn` handles here.
- **Keep the Linear description lean** (title + the Goal line below); this spec is
  the engineering detail the ticket is written *from*, so the ticket body can point
  back to the relevant section rather than copying it.
- Labels: `diff-viewer` for the chrome-facing work, `persistence` for T1, `github`
  for Phase 2-3. Create any that do not exist yet (labels slice across the four
  durable projects; the epic Project is separate from those).

The tickets below are written out in full so the research context is not lost.
Dependencies are hard ordering constraints (a ticket cannot start until its
dependencies merge).

---

**T1 — Review model + persisted store** · Milestone: Local foundation · Label:
`persistence` · Priority: High · Depends on: none
- **Goal.** A durable, per-branch review store the rest of the epic reads and writes.
- **Scope.** New `ReviewModel.swift` (see Architecture › Data model): `ReviewDocument`
  versioned envelope, `ReviewState`, `ReviewComment`, `FileReviewState`,
  `ReviewReply`, `Reaction`, `GitHubLink`; add `Codable` to `DiffScope`/`ChangeKind`;
  hand-rolled tolerant `Decodable` with `.unknown` fallback on `origin`/`kind`
  (model on `NavCommand.decode`); ISO8601 dates. New `ReviewStore.swift` (see
  Architecture › Store concurrency): plain `final class`, in-memory state on main,
  serial I/O queue, whole-state atomic save via the reused `TrailingDebouncer`,
  process-level `[URL: ReviewStore]` registry keyed by `repoRoot`, load-once at
  construction off-main, never throw on I/O failure. New `ReviewStoreKey.swift`:
  `repoID` from `git config --get remote.origin.url` normalized to `host/owner/repo`,
  hash-of-`repoRoot` fallback; `branch` from `headOverride?.name ?? currentBranch`,
  detached → short HEAD SHA; PR → `pull/<n>`. No UI in this ticket.
- **Tests.** Codable round-trip; unknown-enum tolerance (bogus `"kind"` decodes to
  `.unknown`, does not throw); schema-version mismatch degrades to empty; `repoID`
  derivation and slugging; missing file → empty review; save coalescing with an
  **injected** debouncer scheduler; a `#if DEBUG` scratch-dir override like
  `ConfigLoader.defaultRootOverrideForTesting` (never touch real
  `~/Library/Application Support`).

**T2 — Anchoring engine** · Milestone: Local foundation · Label: `diff-viewer` ·
Priority: High · Depends on: T1
- **Goal.** Re-locate a comment's lines as the file drifts, or mark it outdated.
- **Scope.** New `CommentAnchor.swift` and `AnchorResolver.swift` (see Architecture ›
  Anchoring and staleness). `CommentAnchor` distills `DiffSelection` (`newRange`,
  `anchorNewLine`, `removedLines`) plus `snapshot`, `contextBefore/After`, `headSHA`,
  `side`. `AnchorResolver.resolve(anchor, newSideLines:currentHeadSHA:)` pure, the
  SHA-exact → content-relocate → outdated ladder, removals-only handled via the
  following line's text. No git and no AppKit in this ticket (caller supplies content
  from `GitDiffRunner.blobText`).
- **Tests.** Pure, over hand-built line arrays: SHA-exact hit; single relocate;
  ambiguous relocate resolved by context then nearest; zero-match → outdated clamped
  to file length; removals-only. Prove each can fail first.

**T3 — Persist-on-send + request-changes** · Milestone: Local foundation · Label:
`diff-viewer` · Priority: High · Depends on: T1, T2
- **Goal.** Composing a comment persists it, and a comment can request changes;
  the immediate agent fire stays first-class.
- **Scope.** `DiffCommentComposer.swift` gains a Comment/Request-changes
  `SegmentedControl` and a **Save** action beside Submit/Queue (copy via
  `docs/brand-voice.md`). `DiffViewerOverlay.openComposer/send` builds a
  `ReviewComment` (from the `DiffSelection` + a `CommentAnchor`, `headSHA` from a
  one-shot `git rev-parse` on the store queue) and calls `ReviewStore.addComment`
  **before** invoking the existing `sender` — Submit and Queue still paste/fire now
  (persistence is additive). Wire a `ReviewContext { repoID, branchProvider }` + the
  `ReviewStore` into `WindowController.presentDiffViewer` as new injected closures
  (never the store type directly).
- **Tests.** Window-based composer interaction (segmented control toggles kind, Save
  persists without firing the sender, Submit persists **and** fires); a stub store
  asserts the `ReviewComment` shape; Tab focus ring still correct. New chord (if any)
  gets a runbook line.

**T4 — Mark-as-reviewed + roll-up** · Milestone: Local foundation · Label:
`diff-viewer` · Priority: Medium · Depends on: T1
- **Goal.** Mark a file reviewed from the tree; show review progress; un-review on
  change.
- **Scope.** Toggle `FileReviewState` from the file tree (`DiffOutlineItem`,
  `DiffTreeOutlineController`) with a checkmark and a greyed/dimmed reviewed row;
  footer roll-up `n comments · m to review` via `ReviewState` roll-ups
  (`DiffViewerOverlay` footer/hints); clear the mark when `reviewedAtHeadSHA` no
  longer matches the file's current head. A reviewed-toggle chord is reasonable (bare
  key, view-local like the other diff keys).
- **Tests.** Window-based: toggling the tree row writes the store and renders the
  checkmark; a head change clears a stale mark; footer roll-up updates. Runbook line
  for the chord; layout/color to the runbook.

**T5 — Render persisted comments + gutter markers (conservative)** · Milestone:
Local foundation · Label: `diff-viewer` · Priority: Medium · Depends on: T2, T3
- **Goal.** See where comments are and open one, without the variable-height refactor.
- **Scope.** Gutter markers on commented new-side lines in `DiffPaneTable` (looked up
  by row index every `viewFor:`, re-stamped through `refreshDecoration()` /
  `enumerateAvailableRowViews` so an on-screen change shows immediately). **Reuse the
  existing single `composerBox`** to view/edit one comment at a time (click a marker →
  open the box prefilled on that line). Resolve a file's comments through
  `AnchorResolver` **inside** the single `renderRows` pass (never a second paint —
  it closes the composer and loses typed text); blob content fetched off-main. Outdated
  anchors render greyed, not interleaved. Explicitly **out of scope:** multiple
  simultaneous inline threads (that is T9).
- **Tests.** Window-based on a real `DiffPaneTable` in a `WindowTestCase` suite: a
  commented line shows a marker (new `commentMarkerForTesting(row:)` hook); clicking
  opens the prefilled box; an outdated comment badges greyed. Prove-it-can-fail first.

**T6 — Send whole review to agent** · Milestone: Local foundation · Label:
`diff-viewer` · Priority: Medium · Depends on: T1, T3
- **Goal.** The payoff of "persist then act": the agent consumes the whole review.
- **Scope.** New `ReviewToAgent.swift` builds one consolidated message from all
  `ReviewState.comments` (each a `DiffReference` + body, change-requests flagged),
  reusing `DiffSendTarget`/`sender`/`TabController.send`. A footer "Send review"
  action. No new pasteboard use (confirm the path is `paste`/`submitLine`, not a
  clipboard).
- **Tests.** Pure: the consolidated message format for N comments incl. a
  change-request and a removals-only comment. Window-based: the footer action sends to
  the chosen target via a stub sender.

**T7 — GitHub seam + `gh` client (read)** · Milestone: GitHub read · Label:
`github` · Priority: High · Depends on: T1
- **Goal.** A protocol-hidden `gh`-backed source for PR reads.
- **Scope.** New `GitHubReviewSource.swift` (protocol) + `GHCLIReviewSource.swift` +
  `GHCLI.swift` (see Architecture › GitHub seam). This ticket: `listPullRequests`,
  `resolvePullRequest`, `pullRequestDiff` only. `Process` off-main draining both pipes
  before `waitUntilExit` (stderr concurrently), decode on the background queue, one
  main hop; typed `Failure { ghUnavailable; ghError; decodingFailed }`. Injected as a
  closure like `Loader`, never constructed inside a view.
- **Tests.** Pure command-builder (each method's argv) + `gh` JSON → model decode
  against fixture strings (like `GitDiffRunner.diffArguments`); the `Process` half is
  untested directly, exercised only through the injected seam. Never run real `gh`.

**T8 — PR targets in the head picker** · Milestone: GitHub read · Label: `github` ·
Priority: High · Depends on: T7
- **Goal.** Point the viewer at a PR, not just a local branch/base.
- **Scope.** `DiffTarget { localBranch(BranchOption); pullRequest(PullRequestSummary) }`
  in the overlay; a PR section in `headsLoader` (populated by `listPullRequests`,
  omitted when `gh` is unavailable); route the existing `loader` for `.pullRequest`
  through `resolvePullRequest` + `pullRequestDiff` → `DiffParser.parse` → stamp → a
  committed-only `StatusLoad` (the `head?.hasWorktree == false` shape). Review key
  becomes `pull/<n>`. Render/place-restore/highlight/single-flight untouched.
- **Tests.** Pure: PR-diff parse → committed-only `StatusLoad`; key derivation
  `pull/<n>`. Window-based: the head picker shows a PR section from a stub source and
  omits it on `ghUnavailable`.

**T9 — Reviewer comments (read) + multi-thread inline view** · Milestone: GitHub read
· Label: `github` · Priority: High · Depends on: T5, T7, T8
- **Goal.** Show GitHub reviewer threads inline. **This is the variable-height design
  pass**, deliberately deferred here.
- **Scope.** `reviewThreads` (`gh api graphql`) → `[ReviewComment(origin: .github)]`
  with `GitHubLink` populated and `anchor.snapshot` seeded from `diffHunk`;
  resolved/outdated badges from `isResolved` + `position == null`. Generalize
  `DiffPaneTable`'s scalar `composerAnchor`/`composerHeight` into a per-row height map
  with N floating subviews (the open composer plus any expanded threads), all in the
  document coordinate space and re-framed in `layout()`; new `DiffCommentThreadView`.
  **Revisit the scroll math** (`centerRow`/`jumpChange`/`halfPage`) that assumes a
  uniform `DiffCellMetrics.rowHeight`. Selection re-stamp must survive repeated
  reloads. Candidate new `docs/swift-conventions.md` entry.
- **Tests.** Window-based: two threads open at once size independently and push lines
  correctly (`rowOriginForTesting`); half-page/jump-to-change land right with mixed
  row heights; a resolved thread badges. Pure: `graphql` JSON → `ReviewComment` map.
  Budget this ticket larger than the others.

**T10 — Post review to GitHub** · Milestone: GitHub write · Label: `github` ·
Priority: Medium · Depends on: T7, T9
- **Goal.** Push stored local comments as a GitHub review; choose local vs push.
- **Scope.** `submitReview(number, event:, body:, comments:)` →
  `gh api .../pulls/{n}/reviews`, event comment/approve/request-changes; each local
  `ReviewComment` whose `ResolvedAnchor.status != .outdated` posts inline (`path`,
  `line`/`start_line`, `side`), outdated ones fall back to a file-level comment. A
  per-comment (or per-review) keep-local-vs-push choice; on success stamp `GitHubLink`
  so a re-post updates rather than duplicates.
- **Tests.** Pure: local comments → the reviews-endpoint JSON body, incl. the outdated
  fallback and the change-request → event mapping. Window-based: the push affordance
  and its confirmation copy. Never run real `gh`.

**T11 — Reply to a thread** · Milestone: GitHub write · Label: `github` ·
Priority: Low · Depends on: T9, T10
- **Goal.** Reply inline to a GitHub thread.
- **Scope.** `reply(to:in:body:)` → `gh api .../pulls/{n}/comments -F in_reply_to=…`;
  append a `ReviewReply` to the local `ReviewComment` and to the thread view.
- **Tests.** Pure: reply command build + response → `ReviewReply`. Window-based: the
  reply field posts via a stub and appends the reply.

**T12 — Reactions / emoji** · Milestone: GitHub write · Label: `github` ·
Priority: Low · Depends on: T9
- **Goal.** React to a comment with an emoji.
- **Scope.** `addReaction(content, toCommentID:)` →
  `gh api .../pulls/comments/{id}/reactions`; update the `Reaction` rollup and the
  thread view's reaction row.
- **Tests.** Pure: reaction command build + rollup update. Window-based: the reaction
  affordance updates the row via a stub.

## Verification

- **Per ticket:** `bin/check` fully green (build, `swift test`,
  `swift format lint --strict`, `swiftlint --strict`) — the CI gate.
- **Pure model/anchoring/store** (T1, T2): `swift test` round-trips, tolerant
  decode, the four resolver outcomes, injected scratch dir + injected debouncer
  (no wall-clock sleeps, no real `~/Library/Application Support`, no real config).
- **AppKit surfaces** (T3-T5, T9): window-based interaction tests on a real
  `DiffPaneTable`/`DiffViewerOverlay` in a `WindowTestCase`-derived suite (marks,
  gutter markers, request-changes control), asserted via test hooks like the
  existing `rowOriginForTesting`; prove each new test can fail first. Layout,
  placement, and color go to the runbook, not a test.
- **`gh` client** (T7): pure command-builder + fixture-JSON decode tests; never run
  the real `gh` binary; the `Process` half is exercised only through the injected
  closure seam, like `runGit` itself.
- **End-to-end, in the running app** (`swift run ZenTerm`, or the `drive-dev-app`
  skill when Drew asks): open ⌘D, comment on a selection, confirm it persists across
  a viewer close/reopen and an app relaunch for the same branch, mark a file
  reviewed, "Send review" into a pane; Phase 2+, pick a PR target and read reviewer
  threads. A new chord always gets a runbook line (it crosses `KeyInterceptor`
  before the responder chain, which no view test covers).
