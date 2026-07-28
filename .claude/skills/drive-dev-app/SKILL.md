---
name: drive-dev-app
description: Drive an in-flight `bin/run` dev build of ZenTerm to verify behavior no test can reach. Launches the worktree build, proves it contains the change, sends commands and chords into its panes, screenshots to inspect state. Use when a runbook step needs the running app rather than Drew's eyes. Never targets the installed or Dev app.
---

# Driving the dev app (zen-term)

Some behavior is only true in the running app: process teardown across a real pane,
a chord crossing `KeyInterceptor`, anything spanning the chrome and a live shell.
`docs/gui-runbook.md` covers what to **hand to Drew**. This covers what you can
**verify yourself**, which is anything with a machine-checkable outcome (a process
died, a port freed, a window closed).

The split is the outcome, not the surface:

- **Drive it here** when the result is checkable without eyes: a pid exits, a port
  releases, a file changes, a window count drops.
- **Hand it to Drew** when the result is layout, spacing, motion, color, or focus
  rings. A screenshot proves a thing is on screen, not that it looks right.

## The safety model, and why it is shaped this way

**Both instances present to System Events as "ZenTerm".** Drew runs the installed
app and `ZenTerm Dev.app` daily, and a Claude Code session usually lives in a pane
of one of them. A keystroke goes to whatever is frontmost. Targeting by name will
eventually type a command into the session driving it.

So `zt-drive.sh` resolves its target **by binary path**: `bin/run` produces
`.build/<triple>/debug/ZenTerm`, and the other instances are bundles under
/Applications. The script accepts only a `.build/` path, which makes it
structurally incapable of driving the instance hosting a session. **Do not add a
by-name lookup.** That single property is the safety model; everything else is
secondary.

On top of it: every input action focuses the target and re-confirms the frontmost
pid immediately before sending, and aborts if it does not match. Focus is racy, so
a check performed any earlier is worthless.

## The second guard: what the text is allowed to say

The focus guard stops input reaching the **wrong** window. It does nothing about
dangerous input reaching the **right** one, and this script's total power over the
machine is "put one line in a shell and press Return". So that line is the real
security boundary, and `validate_text` is the guard that matters most:

- **One line only.** A newline is a second command the caller never declared, and
  is how a harmless-looking string smuggles one in.
- **A blunt denylist**: `rm -rf`, `sudo`, `dd`, `mkfs`/`diskutil`, redirection into
  a raw device, `shutdown`/`reboot`, `killall`, recursive `chmod`/`chown`,
  `csrutil`/`spctl`/`tccutil`/`nvram`, `launchctl bootout`, `defaults delete`,
  `git push`/`reset --hard`/`clean`, fork bombs, and `curl | sh`. A runbook fixture
  needs none of these, so a false positive costs a rephrase and a false negative
  costs the machine.
- **No real home paths** (`~/Desktop`, `~/Documents`, `~/Library`). A runbook that
  writes there is doing something it should do from the tool shell instead.
- **`chord` is single-key only**, with an allowlisted modifier set, so text cannot
  arrive through the path that skips validation.
- **Refuses to run as root**, caps a session at 200 synthesized actions so a
  runaway loop cannot keep typing, and puts a 10s timeout on every `osascript` call
  so a hung UI cannot wedge the run.

Verify the guards still hold after editing them. `.claude/skills/drive-dev-app/`
has no test harness by design (it would need the dangerous strings on disk), so
regenerate payloads from fragments and check every one is refused.

## On sandboxing: what is and is not possible

**Synthetic input cannot be sandboxed on macOS.** `CGEvent` and System Events post
to the *session* event stream and the OS routes by what is frontmost. Nothing can
scope a keystroke to one process, so containing ZenTerm would not help: the input
originates in `osascript`, not in the app.

Real isolation means a real guest:

- **A macOS VM** (`tart`, Virtualization.framework on Apple Silicon) is the only
  true answer. The Accessibility grant still has to exist, but it exists *inside a
  throwaway guest*, which is the entire point. Cost: a macOS image, the Swift
  toolchain, and a `bin/build-ghosttykit` run in the guest.
- Separate Spaces or desktops are **cosmetic** and provide no isolation.

Until that exists, the guards above are the containment, and they are why the
denylist is deliberately over-broad.

**TCC grants outlive this script.** Accessibility and Screen Recording attach to
the *responsible process*, which for a shell in a pane is `ZenTerm Dev.app`. So
once granted, anything running in any pane of that app can synthesize input and
capture the screen. Tell Drew when a session is done if he may want to revoke them
in System Settings > Privacy & Security.

## Prerequisites

The tool shell needs two TCC grants, both one-time, both in System Settings >
Privacy & Security:

- **Accessibility** (send keystrokes)
- **Screen Recording** (screenshots)

`zt-drive.sh preflight` reports which are missing. If either is denied, say so and
hand the runbook to Drew instead of working around it.

## The flow

Run everything from the worktree root.

```bash
S=.claude/skills/drive-dev-app/zt-drive.sh

$S preflight                      # permissions + what is already running
$S launch                         # bin/run in the background, waits for it
$S verify-symbol drainAllSessions # PROVE the build has your change
```

**`verify-symbol` is not optional.** Drew's Dev app can be hours stale, and a
runbook run against a stale binary tests the bug you are trying to fix and passes
for the wrong reason. Pass any symbol your change introduces.

Then drive it:

```bash
$S run 'python3 /tmp/fixture.py 8931'   # paste a command into the focused pane
$S chord '\' command,shift              # split a pane
$S chord w command                      # close the focused pane
$S quit                                 # ⌘Q
$S shot /tmp/state.png                  # then Read the png to inspect
$S port 8931                            # LISTENING | free
$S waitgone 34668 30                    # poll until a pid exits
$S sweep                                # ALWAYS, at the end
```

## Getting the chord right

Read the default from source, then check Drew's config for an override, because a
user keybind **moves** the action and unbinds the default:

```bash
grep -n 'map\[Chord' Sources/ZenTerm/Keybinds.swift        # defaults
grep -n 'keybind' ~/.config/zen-term/config                # overrides
```

Never guess a chord and send it. An unknown chord in a terminal is arbitrary input.

## Rules that came from getting this wrong

- **Paste, never type.** `zt-drive.sh run` uses the clipboard and ⌘V. Per-character
  `keystroke` silently drops characters on long strings: it once turned `python3`
  into `nepython3`, which failed loudly, but a dropped character in a `rm` argument
  would not. The script saves and restores the clipboard around the paste.
- **Poll for the condition, never sleep and look once.** Use `waitgone` / `port`.
  A fixed sleep is a flake on a loaded machine and a tax on every green run.
- **Bound every fixture you spawn.** A test fixture must not be able to outlive the
  run. Prefer something self-limiting over anything that needs cleanup to work, and
  never `2>/dev/null` a cleanup command: that hides the one failure that matters.
- **`sweep` at the end, every time.** Report what it finds. A leaked process is
  Drew's machine, not a tidiness issue.
- **Quitting the app ends the run.** `bin/run` exits with it, so relaunch to
  continue.

## Reporting

Report what was checked and what was not. A driven runbook covers the paths you
actually exercised; say plainly which steps were covered by tests instead, and
which still need Drew's eyes. Do not describe a step as verified because a related
one passed.
