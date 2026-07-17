# zen-term — Project Rules

Native macOS terminal. **The chrome is the product; the terminal is a drop-in
dependency behind the `TerminalSurface` seam.** Swift + SwiftPM + AppKit over
libghostty (the sole backend, embedded as `GhosttyKit`). Global workflow rules in
`~/.claude/CLAUDE.md` apply; this file only adds what's specific to zen-term.

**Everything in `docs/` describes what is true today.** `docs/architecture.md` is
the one architecture doc. If a change makes it wrong, the change fixes it.

A spec or plan belongs in `docs/` **while the work is in flight**. It exists to
work out implementation details and to fill out the tickets, and it is spent once
the tickets and the code exist. When the epic ships: fold anything architectural
into `docs/architecture.md`, then delete the plan, or archive it if it still
answers something the code and the tickets don't. A shipped epic's plan describes
intent the code already superseded, so leaving it in place only leaves something
that can be wrong.

The record is **Linear** (projects, tickets, PR links) and git. `docs/` is not a
second copy of it.

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
**AppKit controls get window-based interaction tests, not state-only tests** —
assert the control by driving it in a real window, because a test that only
checks the backing view-model passes while the control is dead (that's exactly
how a fully broken dropdown shipped past two reviews). **The event has to be real
too:** AppKit puts `.function` **and** `.numericPad` on every arrow `keyDown`, so
a synthesized `modifierFlags: .option` is a keystroke macOS never sends — that
shipped a ⌥-arrow reorder that did *nothing* in the app, past four green tests
and a mutation check, because both only ever exercised the fake event (ZEN-145).
Build synthesized events the way AppKit delivers them, and match modifiers
against the reservable set (`[.command, .shift, .option, .control]`) rather than
`.deviceIndependentFlagsMask`, which keeps those extra bits and so never compares
equal to a bare modifier. A keyboard path also crosses `KeyInterceptor`'s event
monitor *before* the responder chain, which no view-level test covers — so hand a
new chord to the runbook even when it looks fully tested. Reserve the manual
runbook for that, and for genuinely visual behavior (motion, layout, color) no
test can assert.

## Releasing

Public releases are cut locally with `bin/release` — preflight (clean
main, cert, notary profile, releases repo) → `bin/check` → assemble + Developer
ID sign (`bin/package-app`) → notarize + staple app and DMG → verify gates →
curated notes → tag `vX.Y.Z` on this repo → publish the DMG to the **public**
`zen-term/zen-term-releases` repo (this repo is private, so its own Releases
aren't downloadable). arm64-only; version source of truth is the git tag.

**Versioning is automatic**: bare `bin/release` patch-bumps the last tag (semver;
see the README's "Version numbers" for which bump to pick), `bin/release
major|minor|patch` picks a component, `bin/release X.Y.Z` names one outright.
Three guards there are load-bearing, so don't "simplify" them away: a tag already
at HEAD means **resume**, not bump (it's what stops a rerun from stranding a
half-published tag); `git describe` is `--match`ed to `vX.Y.Z` and the resolved
version is re-checked against the semver regex (an unfiltered describe hands a
`checkpoint` tag to the bump arithmetic and publishes the garbage); and the
version resolves **after** `git fetch --tags`, because a stale local tag set
otherwise publishes below what's already released. A version is also refused if
it doesn't ascend past the last tag, including one named by hand.

`bin/package-app` alone still produces the ad-hoc-signed daily-driver build, and
stamps `<last-tag>+<commits since>` (e.g. `0.1.0+7`) so a dogfood bug report names
an exact build. It counts **commits, not PRs**: main carries direct-to-main
commits alongside squash-merges. `CFBundleVersion` stays the total commit count:
it must be globally monotonic for Sparkle, and `+N` resets at every tag.

One-time setup: a "Developer ID Application" cert in the keychain, and
`xcrun notarytool store-credentials zenterm-notary --apple-id <id> --team-id
<team>` with an app-specific password.

## Architecture — the seam (load-bearing)

- `Sources/TerminalKit/` owns the seam (`TerminalSurface` protocol + types) and
  the libghostty backend. It is the **only** target that depends on `GhosttyKit`.
- `Sources/ZenTerm/` is the chrome. It depends on `TerminalKit` **only** and must
  never `import GhosttyKit` (or any backend). This is enforced at the module level
  in `Package.swift` — the app target has no backend dependency to import.
- Anything only one backend can do stays **below** the seam; the protocol grows
  only to hold what the chrome needs from *any* terminal.

## Swift conventions

- PascalCase types; one primary type per file; filename matches the type.
- Public API in `TerminalKit` is `public`. Prefer `struct` / `final class` /
  `type`.
- No force-unwrap except documented AppKit (`contentView!`).
- **Never block the main thread.** No synchronous subprocess (`waitUntilExit`),
  file-system walk, or blocking I/O on the main queue — the chrome *is* the
  product, and a stalled main thread is a beachball (ZEN-90). Do the work
  off-main and hop back to main for the UI update.
- Per global rules: no `TODO`/`FIXME`/`HACK` markers — fix it now, or file a
  Linear ticket for genuinely out-of-scope work.

## Copy: read `docs/brand-voice.md` first (load-bearing)

**Any word a person outside the project reads is governed by
`docs/brand-voice.md`.** That includes in-app copy (toasts, empty states, button
labels, Settings captions, error messages), `docs/config/*` (users open those
files), the README, release notes, and anything in `zen-term-website` or
`zen-term-releases`. Read it before writing or editing user-facing copy, not
after.

The parts that get violated most:

- **No em-dashes. Anywhere**, including inside quotes. Plenty of good writing
  uses them, which is why this is the rule that drifts back.
- **No hype words, no adverbs.** The app's user-facing copy currently contains
  zero instances of "seamless", "powerful", "beautiful", or "just works". That's
  a property worth keeping, not an accident.
- **Positioning:** ZenTerm is "a terminal for the modern era", a modern shell for
  a great terminal (ghostty), for terminal devs of all kinds. The agentic bent is
  a lean, never the frame. Do not write "the terminal for the agentic era".
- **One word per concept** (pane not split, workspace not project/repo, shortcut
  not keybind). The vocabulary table is in the doc.
- Confirmations state the consequence and never ask "Are you sure?".

`docs/brand-voice.md` lives here (the source) and is mirrored into the website
repo. Edit it here, then copy it out. **It does not go in `zen-term-releases`**:
that repo is public, and how we talk about ZenTerm is guidance for whoever writes
the copy, not something a user downloading the app should be handed.

## Colors — always theme-driven (ZEN-27)

The chrome must **never hardcode a color**. A hardcoded color won't follow a
bring-your-own theme and washes out on light themes. Every color resolves from
`Theme.current`:

- **Terminal surfaces:** build `TerminalSurfaceConfig(theme: Theme.current.terminal)`.
- **Chrome UI (`Sources/ZenTerm/`):** use `Theme.current.chrome` roles —
  `background`, `foreground`, `info`, `warning`, `destructive`, `accent`,
  `attention`, `muted` — and `chrome.ink(alpha:)` for foreground-toned inks,
  hairlines, and hover fills (it applies the readability boost; pass the site's
  opacity, not a raw `NSColor`).

**Banned in the chrome:** `NSColor(white:…)`, `.white` / `.black`, raw hex,
literal palette values (`0xc4a7e7`, `NSColor(srgbRed:…)`), and AppKit
system/semantic colors (`.secondaryLabelColor`, `.placeholderTextColor`, a text
field's default `placeholderString` tint, …) — those follow `effectiveAppearance`,
not `Theme.current`, so they wash out on light themes. The only exception is a
genuinely theme-independent value (e.g. the black drop shadow in `FloatShadow`),
and it must be commented as such. If a chrome element needs a role `ChromeTheme`
doesn't expose, add the role and derive it from the terminal palette in
`ChromeThemeDeriver` — never reach for a literal.

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

- **Linear is the record.** The project, its tickets, and their PR links are the
  durable history of an epic. Don't write a second copy into `docs/`.
- **A spec or plan is scratch**, for working out implementation details and for
  writing the tickets from. It lives in `docs/` while the epic is in flight, and
  gets cleaned up when the epic ships: fold anything architectural into
  `docs/architecture.md`, then delete or archive it.
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
5. **Close out** — mark the PR ready for review. Linear moves the ticket to **In
   Review** itself once it's ready (auto-linked via the issue id), so don't set
   that status by hand. On a **local-only** ship there's no PR to trigger it, so
   move it yourself (`c8f755f6-5c17-4bdd-b41f-9161166fdb19`). Done is reached on
   merge, or by hand on a local-only ship.

Status flow the agent drives: **In Progress** on pickup. **In Review** and **Done**
follow the PR on their own. Backlog → Todo → In Progress moves are yours.
