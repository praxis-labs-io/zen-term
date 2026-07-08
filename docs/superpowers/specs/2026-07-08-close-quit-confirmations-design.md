# Close & quit confirmations — design

Guard destructive close gestures with a blocking confirmation built on the toast
infrastructure. Two flows share one component family:

- **⌘W (per-tab):** confirm before closing a split that has a running foreground
  process, or the last split of a tab (which destroys the tab).
- **⌘Q (app quit):** confirm before quitting, showing how many tabs will close.

Stacked on the `feature/zen-48-…` branch — it introduced the toast infra
(`ToastView` / `ToastPresenter`) this builds on. Linear: ZEN-49 (the ⌘W flow);
the ⌘Q flow rides the same change.

## Scope

In:

- Blocking modal confirmations, top-right, on the existing toast card chrome.
- `ToastView` gains an optional actions row + a sticky (no-auto-dismiss) mode.
- A themed text button primitive for toast actions.
- A below-the-seam "is this shell busy" signal (`TerminalSurface.isBusy`).
- ⌘W trigger logic; ⌘Q trigger via `applicationShouldTerminate`.

Out (explicit):

- **`exit` / ⌘D in a shell** — an explicit in-shell decision; never intercepted.
- **Middle-click-to-close a tab** — stays instant for now (routes through the
  same `closeTab`, so it's a trivial later addition).
- No backdrop, no centered dialog — the confirm stays a top-right card.

## Interaction model — blocking modal

A confirmation is a blocking gate, matching the lazygit-float / palette pattern
already in `WindowController`:

- Presenting it moves first responder into the confirm's **primary button**, so
  terminal input is gated (keystrokes don't reach the shell).
- `WindowController` adds an `isConfirmOpen` case to the same modal chord-gate
  that lazygit and the palettes use — ⌘W, splits, nav, drawers, zoom are
  swallowed while a confirm is up.
- **Enter** activates the primary (`keyEquivalent = "\r"`); **Esc** activates
  cancel (`keyEquivalent = "\u{1b}"`) — native `NSButton` key equivalents, no
  custom monitor.
- It never auto-dismisses. Dismiss (either button) restores unified focus to the
  pane.

## Components — extend the toast infra

Chosen over a separate centered `ConfirmOverlay`: keeps the top-right placement
and the card look already tuned in ZEN-48, and the blocking behavior comes from
native button key equivalents + the existing modal gate rather than a new overlay
class.

### `ToastAction`

```
struct ToastAction {
    enum Kind { case primary, cancel, destructive }
    let title: String
    let kind: Kind
    let run: () -> Void
}
```

### `ToastButton` (new)

A small themed pill button on the toast card:

- **primary** — gold fill (`ToastPresenter.warning` / theme gold), dark text.
- **destructive** — red-tinted (Rosé Pine Moon `love`), used for the confirming
  action when it's a delete-flavored verb ("Close", "Quit").
- **cancel** — bordered/ghost, muted foreground.

Carries its `ToastAction.run` and the appropriate `keyEquivalent`.

### `ToastView` changes

- Optional `actions: [ToastAction]` passed at init.
- When non-empty: render a trailing-aligned button row below the message, and
  **do not auto-dismiss** (sticky). When empty: unchanged (passive toast).
- The passive path (icon + title + message, 4s auto-dismiss) is untouched.

### `ToastPresenter.confirm(...)`

```
func confirm(_ content: ToastContent, tint:, actions: [ToastAction])
```

Presents a sticky action toast (no timer). Reuses the existing spring-in /
spring-out + top-right stacking. Because confirmations are modal and mutually
exclusive with the app's other modes, only one confirm is shown at a time.

## ⌘W — per-tab confirm

At the `.closePane` dispatch (`WindowController.handle`), before closing, inspect
the focused pane of the active tab:

- **Confirm when** the focused pane `isBusy` **or** it is the tab's **last**
  pane.
- **Otherwise** (idle shell with other panes remaining) → close immediately, as
  today.
- **Close** → run the existing `closeFocused()` → (if last) `closeTab` cascade.
  **Cancel** → no-op.

Copy:

- Last-pane case → title *"Close tab?"*, message *"This closes the tab and its N
  pane(s)."* (drop the pane clause when N == 1).
- Busy-but-not-last case → title *"Close pane?"*, message *"A process is still
  running here."*

Confirming verb button: **"Close"** (destructive kind). Cancel: **"Cancel"**.

### `TerminalSurface.isBusy` (seam addition)

```
var isBusy: Bool { get }   // default false via protocol extension
```

`SwiftTermSurface` implements it from the shell pid (already resolved for cwd via
`proc_pidinfo`) using `proc_listchildpids`: a shell with child processes is
running something (foreground command or a backgrounded job) → busy. Backend-
specific, stays below the seam per the architecture rule; `GhosttySurface` and
any future backend inherit the `false` default until they can answer.

The chrome reads `isBusy` through the focused pane's surface — `TabController`
exposes the focused main-canvas surface's busy state (mirroring how it already
exposes `focusedCWD`).

## ⌘Q — app-quit confirm

`AppDelegate.applicationShouldTerminate(_:)`:

- Count tabs across **all** windows.
- Always confirm when quitting (per decision — quit is high-stakes and the count
  is worth showing, even for a single idle tab).
- Return `.terminateLater`; present the confirm on the **key window**; reply
  `NSApp.reply(toApplicationShouldTerminate:)` `true` on Quit, `false` on Cancel.

Copy: title *"Quit ZenTerm?"*, message *"N tab(s) in M window(s) will close."*
(drop the window clause when M == 1). Confirming verb: **"Quit"** (destructive).

`AppDelegate` reaches the key window's `WindowController` (it already tracks
`windows` and `keyController()`); `WindowController` exposes a
`presentQuitConfirm(tabCount:windowCount:onQuit:onCancel:)`-style entry that wires
the buttons back to the terminate reply.

## Focus & teardown

- Confirm presentation records nothing new to persist — it's transient. On
  dismiss, `WindowController.restoreKeyFocus()` / `restoreUnifiedFocus()` returns
  first responder to the active pane, exactly as palettes do.
- If a window closes or the app quits while a confirm is somehow live, the
  presenter's views are torn down with the container (no retained timers, since
  confirms have none).

## Error handling & edge cases

- **`isBusy` false negatives/positives:** `proc_listchildpids` counts any child,
  including backgrounded jobs — treated as "busy" deliberately (better to confirm
  than to silently kill). If the pid lookup fails, default to `false` (not busy) —
  the last-pane check still guards tab loss.
- **Reduce Motion:** handled by `Motion` (spring completions run synchronously);
  the confirm still gates and still requires an explicit answer.
- **Double gesture:** with a confirm open, further ⌘W / ⌘Q are swallowed by the
  modal gate, so confirms can't stack.

## Testing

- **Unit (TerminalKit):** `isBusy` — a surface running `sleep` reports busy; an
  idle shell reports not busy; a nil/failed pid lookup reports false. (Exercise
  `SwiftTermSurface` against a real short-lived child where feasible; otherwise
  factor the pid→busy check into a pure helper and test that.)
- **Manual runbook (GUI):**
  1. ⌘W on an idle non-last pane → closes instantly (no confirm).
  2. ⌘W on a pane running `vim`/`sleep 60` → confirm; Cancel keeps it; Enter/Close
     kills it.
  3. ⌘W on the last pane of a tab → confirm "Close tab?"; Esc cancels; Close
     destroys the tab.
  4. While a confirm is open, splits/nav/drawer chords are swallowed; Enter =
     Close, Esc = Cancel; focus returns to the pane after either.
  5. ⌘Q with 2 tabs → "Quit ZenTerm? 2 tabs…"; Cancel aborts quit; Quit exits.
  6. ⌘Q with tabs across 2 windows → count includes both, window clause shown.
  7. Reduce Motion on → confirm still appears and gates; no animation.

## Ship

`bin/check` green, `/code-review` on the diff, triage with no tech debt, ZEN-49 →
In Review. Rides PR #23 (the ZEN-48 branch) per the stacking decision.
