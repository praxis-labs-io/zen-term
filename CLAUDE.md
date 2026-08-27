# zen-term: project rules

Native macOS terminal. **The chrome is the product; the terminal is a drop-in
dependency behind the `TerminalSurface` seam.** Swift + SwiftPM + AppKit over
libghostty (the sole backend, embedded as `GhosttyKit`). Global workflow rules in
`~/.claude/CLAUDE.md` apply; this file only adds what is specific to zen-term.

## The docs

**Everything in `docs/` describes what is true today.** If a change makes a doc
wrong, the change fixes it. The app's current state is the benchmark: docs do not
describe cancelled features, speculative work, or how something used to be, except
where a past failure explains why the code is shaped the way it is.

| File | Holds |
|---|---|
| `docs/architecture.md` | what the app is and how it fits together |
| `docs/swift-conventions.md` | AppKit and Swift traps past what a linter catches |
| `docs/brand-voice.md` | every word a person outside the project reads |
| `docs/gui-runbook.md` | how to hand over a manual check list |
| `docs/releasing.md` | `bin/release`, versioning guards, notarization |
| `docs/third-party-notices.md` | re-probing the notices after a ghostty pin move |
| `docs/sparkle-auto-updates.md` | how updates ship, and how to verify one |
| `docs/nvim-navigator-protocol.md` | the nav socket wire contract |
| `docs/nvim-theme-protocol.md` | the published theme contract |
| `docs/config/*` | the reference config files users open |
| `docs/onboarding.md` | the install and first-run narrative |
| `docs/CONTRIBUTING.md` | what an outside contributor reads: setup, the gate, the boundaries |

A spec or plan is **scratch**, not a doc. It lives in `docs/` while an epic is in
flight, to work out implementation details and to write the tickets from, and it is
spent once the tickets and the code exist. When the epic ships: fold anything
architectural into `docs/architecture.md`, then delete it. It is never committed.
The epic's record is **Linear** and git, so `docs/` does not re-copy that history.

## Build / run / test

Terminal-native, no Xcode required (`open Package.swift` only for a
debugger/Instruments session).

- `swift build` / `swift run ZenTerm` / `swift test`
- `bin/check` is **the full local gate** (mirrors CI): build, test,
  `swift format lint --strict`, `swiftlint --strict`. `bin/check --fix`
  auto-applies formatter and linter fixes. Requires `swiftlint`.

**Verify before claiming done:** `bin/check` fully green. Not just build and test:
format-lint and swiftlint are part of the gate and CI enforces them.

### What to test, and what to show

**Test what can be silently dead. Show the rest.** A test earns its keep where a
thing can be broken while looking fine. Anything you would catch by glancing at the
screen goes in the runbook: Drew is at the machine and would rather look than read
an assertion.

- **AppKit controls get window-based interaction tests, not state-only tests.**
  Drive the real control in a real window. A test that only checks the backing
  view-model passes while the control is dead.
- **The event has to be real too.** AppKit puts `.function` and `.numericPad` on
  every arrow `keyDown`, so a synthesized `modifierFlags: .option` is a keystroke
  macOS never sends. Match modifiers against the reservable set (`[.command,
  .shift, .option, .control]`), never `.deviceIndependentFlagsMask`.
- **Prove a new test can fail.** Reinstate the bug and watch it go red. A test
  written against working code can assert the wrong thing and pass for the wrong
  reason.
- **Layout, placement, motion and color are the runbook's, not a test's.** The one
  exception is a budget the eye cannot check: copy against a fixed wrap column
  (`ToastView.messageFont` / `messageMaxWidth`) wraps mid-phrase invisibly, so
  measure that.

The failures behind each of these are in `docs/swift-conventions.md`.

**A runbook is handed over in chat, never written to disk.** One per PR, as a
checklist Drew can work down at the machine. `docs/gui-runbook.md` says how to
build one and when it is required. A new chord always gets a line, because a
keyboard path crosses `KeyInterceptor`'s event monitor *before* the responder
chain and no view-level test covers that.

## Architecture: the seam (load-bearing)

- `Sources/TerminalKit/` owns the seam (`TerminalSurface` protocol + types) and the
  libghostty backend. It is the **only** target that depends on `GhosttyKit`.
- `Sources/ZenTerm/` is the chrome. It depends on `TerminalKit` **only** and must
  never `import GhosttyKit` (or any backend). This is enforced at the module level
  in `Package.swift`: the app target has no backend dependency to import.
- Anything only one backend can do stays **below** the seam. The protocol grows only
  to hold what the chrome needs from *any* terminal.

## Swift conventions

- PascalCase types; one primary type per file; filename matches the type.
- Public API in `TerminalKit` is `public`. Prefer `struct` / `final class` / `type`.
- No force-unwrap except documented AppKit (`contentView!`).
- **Never block the main thread.** No synchronous subprocess (`waitUntilExit`),
  filesystem walk, or blocking I/O on the main queue. The chrome *is* the product,
  and a stalled main thread is a beachball. Work off-main, hop back to main
  for the UI update.
- Per global rules: no `TODO`/`FIXME`/`HACK` markers. Fix it now, or file a Linear
  ticket for genuinely out-of-scope work.
- **Comments cap at 2 lines for `//` and 4 for `///`.** This repo writes far too
  many: 21% of its Swift lines are comment, and 405 doc blocks run past 6 lines.
  Nothing is exempt, file headers included. A block that wants more is the signal
  the global rules already name, that the code needs the work instead of the
  explanation. Long comments already in the tree come down as their files are
  touched, not in a sweep.
- **Read `docs/swift-conventions.md` before touching window sizing, event routing,
  layers, config live-apply, or interaction tests.** Add to it when a new trap bites.

## Copy: read `docs/brand-voice.md` first (load-bearing)

**Any word a person outside the project reads is governed by
`docs/brand-voice.md`.** In-app copy (toasts, empty states, button labels, Settings
captions, errors), `docs/config/*`, the README, release notes, and anything in
`zen-term-website`. Read it before writing, not after.

The rules that get violated most:

- **No em-dashes. Anywhere**, including inside quotes. The test is a grep, not a
  judgment call. Titles take a colon.
- **No hype words, no adverbs.** The app's copy currently contains zero instances
  of "seamless", "powerful", "beautiful", or "just works". Keep it that way.
- **Positioning:** ZenTerm is "a dev-first terminal", on a libghostty core, for
  terminal devs of all kinds. The core is the engine, not the identity: credit it
  plainly in a spec line or the docs, never the headline. The agentic bent is a
  lean, never the frame. Never write "the terminal for the agentic era".
- **One word per concept** (pane not split, workspace not project/repo, shortcut not
  keybind). The vocabulary table is in the doc.
- Confirmations state the consequence and never ask "Are you sure?".

`docs/brand-voice.md` is the source here and is mirrored into the website repo. Edit
it here, then copy it out. It is public along with the rest of this repo, which is
right: it is the standard a contributor's copy is reviewed against, so it has to be
readable by the person writing that copy.

## Colors: always theme-driven

The chrome must **never hardcode a color**. A hardcoded color will not follow a
bring-your-own theme and washes out on light themes. Everything resolves from
`Theme.current`.

- **Terminal surfaces:** build `TerminalSurfaceConfig(theme: Theme.current.terminal)`.
- **Chrome UI:** use `Theme.current.chrome` roles (`background`, `foreground`,
  `info`, `warning`, `destructive`, `accent`, `attention`, `muted`).
- **Text and icons take `chrome.ink(.faint / .muted / .subtle / .normal)`, never an
  alpha.** Four weights, no fifth: `faint` is quieter than what it sits beside (a
  disabled label, a hint opposite a caption), `muted` recedes (captions, hints,
  counts), `subtle` is a control at rest (a toolbar icon, an inactive tab), `normal`
  is active or hovered. A site that wants a weight between two of these is the signal
  that the surface has too many tiers, not that the scale is short.
- **Fills are an order of magnitude fainter than ink, and there are three ways in.**
  A control's interactive fills take a tier, `chrome.fill(.rest / .hover / .active)` —
  never a number, or its states invert on a narrow-separation theme. Structural fills
  (a divider, a border, a swatch ring) take `chrome.fill(alpha:)` with one of the
  named constants `ChromeTheme.hairline / .border / .swatchRing`. A standalone
  role-toned surface behind text (a selected row, a card's icon badge) takes
  `chrome.tint(_:alpha:)`, which is deliberately outside `fillScale`.
- **Never `accent.withAlphaComponent`.** That escapes the per-theme `fillScale` and
  stops the fill being comparable to the others in the same control. Reach for
  `chrome.selectionFill` before defining a new focus or selection fill.

**Banned in the chrome:** `NSColor(white:…)`, `.white` / `.black`, raw hex, literal
palette values, and AppKit system/semantic colors (`.secondaryLabelColor`,
`.placeholderTextColor`, a text field's default `placeholderString` tint, and a field
editor's insertion point, which defaults to the *macOS* accent: call
`applyThemedCaret()` when a field takes focus). Those
follow `effectiveAppearance`, not `Theme.current`. The only exception is a genuinely
theme-independent value (the black drop shadow in `FloatShadow`), and it must be
commented as such. If the chrome needs a role `ChromeTheme` does not expose, add the
role and derive it in `ChromeThemeDeriver`. Never reach for a literal.

## Linear: ZenTerm workspace

The Linear MCP (`linear-zenterm`) is connected to the **ZenTerm** workspace. Every
issue lives on the single **ZenTerm** team (`121e9ab2-6c26-43c8-92f7-953be0396d82`,
key `ZEN`). Status ladder: Backlog, Todo, In Progress, In Review, Done.

- **Address statuses and projects by name, never a UUID.** `save_issue` takes
  `state: "In Review"` and `project: "Polish & Bugs"` directly. Hardcoded ids are
  banned: the 2026-07-19 workspace move invalidated every one, and names survive the
  next move too.
- **Branch names come from the ticket's `gitBranchName` field, verbatim.** Do not
  abbreviate the slug, and do not add or drop a prefix. Reference the issue id in
  commits and PRs so Linear auto-links.
- Every ticket needs a project, a priority, a label, and a status. No orphans. The
  four durable projects are by kind of work: **Polish & Bugs** (rough edge while
  using it), **Feature Backlog** (want a new capability), **Performance and
  Code-Quality** (no user sees a difference), **Release & Distribution** (shipping a
  build). Labels slice across them.

### Epics

- **An epic IS a Linear Project, never an issue.** Task tickets belong directly to
  the project. There is no "epic tracking issue".
- **Create tickets as we go**, never a full backlog dumped up front.
- **A ticket is PR-sized: 1 ticket = 1 branch = 1 PR.** Size to the pull request,
  not to plan tasks. A PR-sized ticket usually bundles several plan steps into one
  independently reviewable, independently mergeable change. Keep descriptions lean:
  a title and a short goal or scope line. The exception is a
  tightly-coupled foundational stack where nothing is separately mergeable; when
  that happens, still create a ticket per task afterward so each keeps its history.

## Contributors

The repo is public and MIT (`LICENSE`, `Copyright (c) 2026 Praxis Labs`).
`docs/CONTRIBUTING.md` is what an outside contributor reads: it is a subset of this
file plus the things only they need. **Keep the two agreeing.** Where they overlap,
this file is the authority; where they disagree, one of them is a bug.

Linear is private, so a `ZEN-` reference is maintainer bookkeeping. Never write copy
or a doc that asks a contributor to look at a ticket, and never gate a contribution
on one existing. An outside pull request gets a ticket created for it, not the other
way round.

## Shipping

The **`ship-feature` skill** owns the PR flow (local gate, draft PR, Copilot +
`/code-review`, triage, ready for review). Cutting a public release is the
**`release` skill**, over `docs/releasing.md`.

**Neither runs on its own.** A feature looking finished is not the trigger; Drew
asking to ship it is. Say the work is ready and stop there.

Two things that flow does not decide for you:

- **Triage leaves no tech debt.** Fix, mitigate, or ignore every finding. Residual
  work becomes a Linear ticket, never an in-code `TODO`.
- **Status:** you drive Backlog to Todo to In Progress. The GitHub integration moves
  In Review and Done on its own once a PR is ready or merged, so do not set those by
  hand.

For a genuinely trivial tweak (a one-line constant), skip the ceremony entirely and
commit straight to main.
