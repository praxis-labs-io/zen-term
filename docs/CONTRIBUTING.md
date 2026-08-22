# Contributing

## Setup

```sh
git clone https://github.com/praxis-labs-io/zen-term.git && cd zen-term
bin/build-ghosttykit
brew install swiftlint
bin/run
```

`bin/build-ghosttykit` inits the `vendor/ghostty` submodule, fetches a Zig
toolchain, and builds `GhosttyKit.xcframework` plus libghostty's runtime
resources. It takes a few minutes and reruns only when the ghostty pin or the
script changes. Its outputs are gitignored and per-machine, so a fresh git
worktree needs `Frameworks/GhosttyKit.xcframework` and
`Sources/TerminalKit/Resources/ghostty-resources` symlinked in from the main
checkout or the build fails.

You need Xcode 26 or later. The manifest declares `swift-tools-version: 6.2`, so
an older toolchain refuses to resolve it, and the Metal compiler is not in the
Command Line Tools alone.

There is no Xcode project. Open `Package.swift` if you want a debugger or
Instruments; everything else is the terminal.

## The gate

`bin/check` is the whole thing, and it is what CI runs.

| Command | Does |
| --- | --- |
| `bin/check` | build, test, `swift format lint --strict`, `swiftlint --strict` |
| `bin/check --fix` | applies the formatter and linter fixes, then tells you to re-run |
| `bin/run` | build and launch |
| `swift test` | tests alone |
| `bin/package-app` | an ad-hoc-signed "ZenTerm Dev.app" in `~/Applications` |

Green means all four, not build and test. Format-lint and swiftlint fail CI on
their own.

## Layout

```
Sources/
  TerminalKit/   the TerminalSurface seam and the libghostty backend
  ZenTerm/       the chrome: panes, tabs, drawers, floats, settings, themes
  PaneKit/       the pane tree and spatial navigation
  TabKit/        the tab list
  AppLog/        the logging facade
```

## Boundaries

Three rules the codebase will not bend on. Each has a failure behind it.

**The seam.** `TerminalKit` is the only target allowed to `import GhosttyKit`.
`ZenTerm` depends on `TerminalKit` alone, and `Package.swift` enforces it by not
giving the app target a backend to import. Anything only one terminal backend can
do stays below the seam. The protocol grows to hold what the chrome needs from
*any* terminal, not what libghostty happens to offer.

**No hardcoded colors in the chrome.** Everything resolves from `Theme.current`:
`chrome.background`, `chrome.foreground`, `chrome.accent`, `chrome.ink(alpha:)`,
and the rest. `NSColor(white:)`, `.white`, raw hex, and AppKit's semantic colors
(`.secondaryLabelColor`, a field editor's default insertion point) all follow
`effectiveAppearance` rather than the theme, so they wash out on a light theme and
ignore a bring-your-own one. If a role is missing, add it to `ChromeTheme` and
derive it in `ChromeThemeDeriver`.

**Never block the main thread.** No `waitUntilExit`, no filesystem walk, no
blocking I/O on the main queue. The chrome is the product and a stalled main
thread is a beachball. Work off-main, hop back to main for the UI update.

[`docs/architecture.md`](architecture.md) is the full picture.
[`docs/swift-conventions.md`](swift-conventions.md) is the AppKit traps past what
a linter catches: read it before touching window sizing, event routing, layers,
config live-apply, or interaction tests.

## Tests

Test what can be silently dead. Show the rest.

**AppKit controls get window-based interaction tests.** Drive the real control in
a real window. A test that only checks the backing view-model passes while the
control is dead on screen.

**The event has to be real too.** AppKit puts `.function` and `.numericPad` on
every arrow `keyDown`, so a synthesized `modifierFlags: .option` is a keystroke
macOS never sends. Match modifiers against `[.command, .shift, .option,
.control]`, never `.deviceIndependentFlagsMask`.

**Prove a new test can fail.** Reinstate the bug and watch it go red. A test
written against working code can assert the wrong thing and pass for the wrong
reason.

**Layout, placement, motion, and color are not a test's job.** They go in the
manual check list a pull request carries. The one exception is a budget the eye
cannot check, like copy measured against a fixed wrap column.

Tests must not touch real OS state: snapshot and restore `NSPasteboard.general`,
pin `GeneralConfig.setCurrentForTesting(.builtIn)`, and never present a real
`NSOpenPanel`.

## Issues and pull requests

**File issues here**, on this repo. The maintainer's planning board is Linear and
it is private, so a `ZEN-` reference in a commit message is a maintainer's
bookkeeping, not something you need or can see. Nothing is gated behind it.

**Help → Report an Issue** inside the app fills in your version, macOS build, and
a system report. It is the fastest way to file a bug that someone can act on.

For a pull request:

- One branch, one pull request, one subject.
- `bin/check` green before you open it. Open it as a draft and mark it ready when
  you are done, so CI runs once rather than on every push.
- Tests belong in the same commit as the behavior they verify.
- Keep implementation, cleanup, and unrelated refactors in separate commits.
- No `TODO` / `FIXME` / `HACK` markers. Fix it, or say in the pull request what
  you left and why.

## Copy

Any word a person outside the project reads is governed by
[`docs/brand-voice.md`](brand-voice.md): in-app strings, the config reference, the
README, release notes. Read it before writing copy, not after.

The three rules that get broken most: no em-dashes anywhere, no hype words, no
adverbs. A confirmation states the consequence and never asks "Are you sure?".

## Docs describe today

Everything in `docs/` describes what is true right now. If your change makes a doc
wrong, the change fixes the doc. Docs do not describe cancelled features or how
something used to work, except where a past failure explains why the code is
shaped the way it is.

| You changed | Read |
| --- | --- |
| a config key or default | `docs/config/config` |
| a keyboard shortcut | `docs/config/config`, `docs/onboarding.md` |
| how a subsystem fits together | `docs/architecture.md` |
| an AppKit trap you hit | `docs/swift-conventions.md`, add to it |
| anything a user reads | `docs/brand-voice.md` first |
| a dependency or bundled resource | `docs/third-party-notices.md` |

## Agents

`CLAUDE.md` at the root is the instruction file for agents working in this repo,
and `AGENTS.md` symlinks to it. It is stricter than this document and it is the
authority where the two overlap.
