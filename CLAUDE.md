# zen-term — Project Rules

Native macOS terminal. **The chrome is the product; the terminal is a drop-in
dependency behind the `TerminalSurface` seam.** Swift + SwiftPM + AppKit over
SwiftTerm (libghostty is a later, optional swap). Global workflow rules in
`~/.claude/CLAUDE.md` apply; this file only adds what's specific to zen-term.

Design source of truth: `docs/superpowers/specs/` (architecture + epic charters)
and `docs/superpowers/plans/` (per-epic implementation plans).

## Build / run / test

Terminal-native — no Xcode required (`open Package.swift` only when you want a
debugger/Instruments session).

- `swift build` — compile
- `swift run ZenTerm` — launch the app
- `swift test` — unit tests (TerminalKit)
- `bin/check` — **the full local gate** (mirrors CI): build → test →
  `swift format lint --strict` → `swiftlint --strict`. Run this before shipping.
  `bin/check --fix` auto-applies swift-format + swiftlint fixes.
  Requires `swiftlint` (`brew install swiftlint`).

**Verify before claiming done:** `bin/check` fully green (not just build +
test — format-lint and swiftlint are part of the gate and CI enforces them).
GUI behavior that has no unit test is verified by running the app and observing
the documented expectation (see each plan's manual runbook).

## Architecture — the seam (load-bearing)

- `Sources/TerminalKit/` owns the seam (`TerminalSurface` protocol + types) and
  the SwiftTerm backend. It is the **only** target that depends on SwiftTerm.
- `Sources/ZenTerm/` is the chrome. It depends on `TerminalKit` **only** and must
  never `import SwiftTerm` (or any backend). This is enforced at the module level
  in `Package.swift` — the app target has no backend dependency to import.
- Anything only one backend can do stays **below** the seam; the protocol grows
  only to hold what the chrome needs from *any* terminal.

## Swift conventions

- PascalCase types; one primary type per file; filename matches the type.
- Public API in `TerminalKit` is `public`. Prefer `struct` / `final class` /
  `type`.
- No force-unwrap except documented AppKit (`contentView!`).
- Per global rules: no `TODO`/`FIXME`/`HACK` markers — fix it now, or file a
  Linear ticket for genuinely out-of-scope work.

## Linear — praxis-labs workspace

The Linear MCP is already connected to the **praxis-labs** workspace
(https://linear.app/praxis-labs). Scope every zen-term issue to the **ZenTerm**
team.

- **Team:** ZenTerm — `1cfb4d81-3e7c-4cc9-bd76-cb3b79b4b8df`
- **Status ladder:** Backlog → Todo → In Progress → In Review → Done
  - Backlog `ed394283-7c1d-4e25-ba0d-d74261d51ef2`
  - Todo `e53f203e-d7d6-4c49-9b9c-8dba0af74217`
  - In Progress `29401739-cb4f-4013-b389-459598f06d8c`
  - In Review `c8f755f6-5c17-4bdd-b41f-9161166fdb19`
  - Done `ceefb860-420c-4640-88d6-70acda792fc6`
- **Team key:** `ZEN`. Use Linear's generated `gitBranchName` for branches;
  reference the issue id in commits/PRs so Linear auto-links.

## Epics → Linear (just-in-time, not up front)

- Epics are documented **locally first** — the charters in the design spec plus a
  per-epic plan. That local pair is the durable record and does not depend on
  Linear.
- **An epic IS a Linear Project — never an issue.** Task tickets belong directly
  to the project. There is no "epic tracking issue"; the project + its child
  tickets are the whole structure.
- **When we pick up an epic:** create/choose its Linear **project**, then create
  tickets under that project **as we go** — never a full backlog dumped up front,
  and never a parent "epic issue" for them to nest under.
- **A ticket is PR-sized: 1 ticket = 1 branch = 1 PR.** Size tickets to the pull
  request, not to plan tasks — a plan's implementation "tasks" are steps, and a
  PR-sized ticket usually bundles several of them into one independently
  reviewable, independently mergeable change. Break an epic into as many PR-sized
  tickets as it takes; don't force one ticket per plan task.
  - Exception — a tightly-coupled foundational stack where each step depends on
    the last and nothing is separately mergeable (e.g. the Epic 0 scaffold: ZEN-2)
    is legitimately one ticket / one PR covering all its plan tasks. When that
    happens, still create a ticket per plan task afterward (linked to the project
    and the PR) so each task keeps its own history — the single PR is the delivery
    unit, the per-task tickets are the record.
- **Branch off the ticket's Linear `gitBranchName`** (from `save_issue`), and
  reference the ticket id in commits/PRs so Linear auto-links. Keep ticket
  descriptions lean: title + a short goal/scope line.

## Shipping a ticket — the `ship-feature` flow

When a task/feature is built, run the `ship-feature` skill
(`.claude/skills/ship-feature/`). Swift/solo-adapted, so PR steps are conditional
on a remote existing:

1. **Local check** — `swift build` clean + `swift test` green (+ formatter/linter
   if configured); confirm any GUI runbook expectations via `swift run ZenTerm`.
2. **Remote check** — no remote yet → local-only ship (skip Copilot/PR). Remote →
   push branch, open a **draft** PR referencing the Linear id, request a Copilot
   review.
3. **Review** — always run `/code-review` on the branch diff; add Copilot findings
   if a PR exists.
4. **Triage** — fix / mitigate / ignore every finding, **no tech debt**. Residual
   work becomes a Linear ticket (ZenTerm team), never an in-code `TODO`. Re-run
   the local check after fixes.
5. **Close out** — move the Linear ticket to **In Review**
   (`c8f755f6-5c17-4bdd-b41f-9161166fdb19`); mark the PR ready if one exists.
   Done is reached on merge (auto-linked via the issue id), or by hand on a
   local-only ship.

Status flow the agent drives: **In Progress** on pickup → **In Review** at ship.
Backlog → Todo → In Progress moves are yours.
