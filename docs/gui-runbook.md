# Running a GUI runbook

zen-term is a GUI app whose features are keyboard-triggered. Anything that has to
be *looked at* is verified with Drew in the running dev build.

The global `interactive-runbook` skill owns the session. It gives one instruction
or makes one controlled fixture change, waits for Drew's observation, records the
result, then advances. It never synthesizes input and never infers a pass from a
screenshot or silence. `drive-dev-app` remains a separately invoked debugging tool,
not part of the normal shipping path.

This is the only standing runbook. Runbooks for individual tickets are **never
written to disk: their checks and results live in the interactive chat session.

## When to run one

- At the end of a major ticket implementation.
- At an intermediary step where the tests are not sufficient confirmation that the
  implementation works. A green suite is evidence about the code paths a test
  drives, not about what is on screen.

GUI changes almost always need one. So does anything crossing `KeyInterceptor`:
its event monitor runs *before* the responder chain, so a control's own `keyDown`
test can pass while the key never reaches it in the running app.

## What goes in one, and what does not

Put it in the runbook when a person at the machine could catch it by looking:
layout, placement, spacing, motion, color, focus rings, whether a keycap landed in
the right corner. A frame-measuring test costs more than it catches and goes green
just as happily when the thing looks wrong.

Write a test instead when the thing can be silently dead while looking fine, or
when the budget is one the eye cannot check. Two of those:

- **Copy against a fixed wrap column.** `ToastView.messageFont` /
  `messageMaxWidth` wraps mid-phrase invisibly, so measure it. This one is about
  text fitting a known width, nothing else.
- **Z-order on a layered view.** Assert the subview index relative to what the view
  must cover. `superview` membership says nothing about paint order, so a card
  buried behind a sibling passes "mounted, on screen, holding first responder"
  while being invisible. See `docs/swift-conventions.md`, "Testing
  AppKit". Still show it in the runbook as well; the assertion is what stops it
  regressing silently.

## Shape

Start with how to get the build running, then order the checks by dependency and
risk. Present only one check at a time, phrased as something to do and something
to see.

```markdown
**Run:** `swift run ZenTerm`

Check 1: Split with `⌘D`. The focused pane should carry the halo and the other
should not. Tell me what you see.

<wait for Drew's result>

Check 2: Press `⌘⌥←`, then `⌘⌥→`. The halo should follow focus in both directions.
Tell me what you see.
```

Rules that keep them useful:

- **One check per turn.** Do not batch instructions or continue before Drew reports
  the result.
- **Every check names the keystroke, click, or fixture change that drives it.** "Verify the halo
  works" is not a check.
- **Wrap chords in backticks.** A bare `⌘⇧\` loses its backslash when the checklist
  is rendered as Markdown, which turns it into a different chord.
- **Every check names what correct looks like**, so a wrong result is reportable
  without a second round trip.
- **A new chord always gets a line**, even when it looks fully tested, for the
  `KeyInterceptor` reason above.
- **Say what is expected to look odd.** If a step is supposed to sit there doing
  nothing for a moment, write that down: silence reads as a broken build.
- **Stop on failure.** Diagnose it, fix it when authorized, repeat the failed check
  from clean state, then resume.
- **Treat teardown as behavior.** An unexpected state while removing a fixture is
  a product failure, not cleanup noise.
- **Clean up controlled fixtures.** Remove temporary files, branches, worktrees,
  and test data, then report that cleanup succeeded.

## Probes handed over for measurement

A probe is an instrument, and an instrument whose failure looks like a valid
reading is worse than none. Anything handed over to measure something must:

- print an initial reading on start, so "alive" is visible
- say what to do, and when to stop
- fail loudly with a distinct message when it cannot take a reading at all
- print a summary line worth pasting back
- prefer polling over signal traps, whose shell semantics vary and can swallow the
  signal

Smoke-test it before handing it over. The tool shell has no tty, so
`script -q /dev/null` is how to give it one.
