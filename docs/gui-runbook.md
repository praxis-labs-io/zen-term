# Handing over a GUI runbook

zen-term is a GUI app whose features are keyboard-triggered. The tool shell has no
TCC permissions, so it cannot screenshot the app or send it keystrokes. Anything
that has to be *looked at* gets handed to Drew as a checklist.

This is the only standing runbook. Runbooks for individual tickets are **never
written to disk**: they are printed in chat, as checkboxes, in the message that
hands the work over.

## When to hand one over

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
  while being invisible (ZEN-141). See `docs/swift-conventions.md`, "Testing
  AppKit". Still show it in the runbook as well; the assertion is what stops it
  regressing silently.

## Shape

Start with how to get the build running, then group the checks by implementation
area. One line per check, each phrased as something to do and something to see.

```markdown
**Run:** `swift run ZenTerm`

**Pane focus halo**
- [ ] Split with ⌘⇧\. The focused pane carries the halo, the other does not.
- [ ] ⌘H / ⌘L moves the halo with the focus.

**Settings card**
- [ ] ⌘, opens it centered, springing in with no flash.
- [ ] Esc closes it and returns focus to the pane that had it.
```

Rules that keep them useful:

- **Every check names the keystroke or click that drives it.** "Verify the halo
  works" is not a check.
- **Every check names what correct looks like**, so a wrong result is reportable
  without a second round trip.
- **A new chord always gets a line**, even when it looks fully tested, for the
  `KeyInterceptor` reason above.
- **Say what is expected to look odd.** If a step is supposed to sit there doing
  nothing for a moment, write that down: silence reads as a broken build.

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
