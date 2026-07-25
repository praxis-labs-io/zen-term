# v0 Launch — Manual Verification Runbook

Manual checks for behavior with **no automated coverage** — the GUI/IME/OS-integration
paths a unit test can't reach (tool-shell TCC blocks screenshots + synthetic keystrokes,
so these are driven by hand on a Mac via `swift run ZenTerm`). Run this pass before
tagging v0.

## Input method (IME) & dead keys — ghostty backend

The ghostty IME path (`GhosttyHostViewIME` preedit state machine) has **zero automated
coverage**. Verify by hand.

**Read this before the dead-key check.** `macos-option-as-alt` defaults to `true`
(`Sources/TerminalKit/TerminalBehavior.swift`, documented for users in `docs/config/config`),
which sends Option as Meta and so bypasses macOS accent composing entirely. That is
deliberate: `⌥f`/`⌥b` word-nav in readline and Meta chords in vim/emacs beat accents for
this audience. Under the default, `⌥e` `e` correctly produces a plain `e`, and the preedit
machinery never runs. Verify both halves:

- [ ] **Option as Alt, on (the shipped default).** With `macos-option-as-alt = true`, type
      `⌥e` then `e` → a plain `e`, no accent, no underlined preedit. In a shell, `⌥f` and
      `⌥b` jump forward and back a word. This is what a new user gets.
- [ ] **Option dead keys, with Option as Alt off.** Set Settings (`⌘,`) → Terminal →
      Option as Alt → Off (it applies in place, no relaunch). Type `⌥e` then `e` → `é`.
      Type `⌥u` then `u` → `ü`. Type `⌥e` then space → a bare `´`. The preedit accent
      renders underlined, then resolves on the second keystroke, with no doubled or
      dropped characters. Set it back to On when you're done, or you lose `⌥f`/`⌥b`
      word-nav in every shell.
- [ ] **CJK IME (Pinyin / Kotoeri).** Switch to a Chinese or Japanese input source,
      type a syllable, and confirm the candidate window appears anchored at the cursor,
      arrow/number selection commits the right glyph, and Esc cancels the preedit
      cleanly (no leftover marked text).
- [ ] **Preedit + focus loss.** Start a CJK composition, click another pane mid-preedit,
      and confirm the marked text commits or clears rather than stranding underlined
      text in the old pane.

## nvim ⇄ ZenTerm seam navigation (nav socket)

The nav-socket → pane-focus dispatch in `AppDelegate` (nvim split handing focus across
the seam) is integration-tested only at the socket layer (`NavSocketServerTests`); the
end-to-end key path is manual:

- [ ] **Ctrl-h/j/k/l across the seam.** Open a workspace with an nvim pane beside a
      shell pane. From nvim's edge split, `Ctrl-h` (or the matching direction) should
      move focus into the ZenTerm pane, not print `^H` inside nvim. From the shell pane,
      the same chord should hand focus back into nvim.
- [ ] **Non-edge split stays in nvim.** With focus on an interior nvim split (not at the
      window edge), `Ctrl-hjkl` moves between nvim splits and does **not** leak to
      ZenTerm pane nav.
- [ ] **Nav socket absent.** Launch without the nvim integration configured and confirm
      `⌘`-based pane nav still works (the socket is opt-in; `⌘`-nav never depends on it).

## Card chords that cross `KeyInterceptor`

`KeyInterceptor` is a local `NSEvent` monitor: it resolves and consumes chords **before**
the responder chain, so a control's own `keyDown` tests can be green while the key never
reaches it in the running app. Nothing at the view level covers that hop. ZEN-145 shipped
a ⌥↑/⌥↓ reorder that did nothing in the app past four green tests — the tests synthesized
an event AppKit never sends (see CLAUDE.md). Any **new chord on a modal card** gets a hand
check here, however well unit-tested it looks.

- [ ] **⌥↑ / ⌥↓ reorder tool floats.** Settings (`⌘,`) → Tools, focus a row, hold ⌥ and
      press ↓ → the float moves down, the dock reorders live *behind* the open card, and
      focus stays on the float that moved (so ⌥↓⌥↓ walks the same one down). ⌥↑ on the
      top row does nothing — it must not wrap to the bottom.
- [ ] **Plain ↑/↓ still move focus** between rows without reordering. The modifier is the
      only difference, and `KeyboardFocus.key(for:)` decodes the keyCode without it.
- [ ] **The order sticks.** Relaunch and confirm the new order holds, that
      `~/.config/zen-term/config` now carries `order:` on every float line, and that
      comments and unrelated keys in that file did not move.
- [ ] **Float dock buttons show their shortcut on hover (ZEN-44).** Hover a tool-float
      button in the footer dock → the tooltip names the float and its toggle glyph (e.g.
      ⌘⇧D), the same way the fixed dock buttons do. Rebind that float's `key:` in the
      config, reload, and the tooltip tracks the new glyph.

## Back to the nav in Settings + form cards (ZEN-217)

Arrows and Tab route back to the left nav through the responder chain. The wiring is
unit-tested (`SettingsGeneralSectionTests`, `SettingsTabTraversalTests`,
`ToolFloatFormOverlayTests`), but whether each key lands on the intended control in the
running card is a hand check.

- [ ] **Left off a General toggle returns to the nav.** Settings (`⌘,`) → General, Tab or
      ↓ into the "Notify me..." On/Off toggle, then ←. With On selected (the leftmost
      segment) focus jumps straight back to the nav and the toggle does not change. With Off
      selected, the first ← cycles to On, the second ← returns to the nav.
- [ ] **Up off the first row returns to the nav.** On any section (General, Appearance),
      focus the top row's control and press ↑. Focus lands on the selected nav row instead
      of dead-ending. ↓ off the last stop still does nothing (no wrap).
- [ ] **The Theme dropdown exits left.** Settings → Appearance, focus the Theme dropdown
      while it is closed, press ←. Focus returns to the nav.
- [ ] **Shift-Tab off the first nav row wraps.** Focus the top nav row (General), press
      ⇧Tab. Focus wraps to the last nav row rather than sticking. ↑ on that same top row
      still clamps (no wrap).
- [ ] **Cancel and Delete are Tab-reachable in the form cards.** Settings → Tools, edit a
      tool float. From Save, Tab walks Save → Cancel → Delete, then wraps to the top field;
      ⇧Tab walks them back. Same in the Add/Edit workspace card.

## ⌘W smart close (crosses `KeyInterceptor`)

⌘W is a global chord: like the card chords above it resolves in `KeyInterceptor`
before the responder chain, so no view-level test sees it decide what to close. It
closes whatever holds focus and confirms only when live work would be lost — an idle
target closes with no toast (ZEN-213). Drive each on a real window.

- [ ] **Drawer-focused ⌘W closes the drawer, not the tab.** Open a drawer (⌘B or
      ⌘\), click into it, ⌘W. An idle drawer closes silently and the tab + panes stay;
      a busy one (run a process in it first) confirms **"Close Drawer"**, and
      confirming kills only that drawer with focus returning to the pane.
- [ ] **Last-pane ⌘W is titled "Close Tab."** On a single-pane tab with something
      running, ⌘W confirms **"Close Tab"** (not "Close Pane"). An idle single-pane tab
      closes with no toast, whether or not other tabs remain.
- [ ] **Split panes.** ⌘W on an idle non-last pane closes it silently; a busy one
      confirms **"Close Pane"**.
- [ ] **⌘W over a tool float is blocked, not a pane close.** With a float open (e.g.
      btop), ⌘W shows the info toast titled **"Tool Float"** reading "Close btop first,
      then ⌘W" — the pane or drawer behind the float is untouched.
- [ ] **⇧⏎ in the ⌘P workspace picker confirms a busy replace.** ⌘P, pick a workspace,
      ⇧⏎. Onto an idle tab it replaces silently; onto a tab with a running pane or
      drawer it confirms **"Replace Tab"** (Cancel keeps the tab). Plain ⏎ still opens
      a new tab.

## Display density across monitors (ZEN-247)

Needs two displays of **different backing scale** (a Retina laptop plus a non-Retina
external is the usual pair), so no test can reach it. The terminal's Metal layer is
layer-*hosting*, meaning AppKit never syncs its `contentsScale` for us; get this wrong and
text stays at the old pixel density and the compositor rescales it, which reads as soft or
chunky rather than obviously broken. Compare against a window born on the target display.

- [ ] **Drag a window between displays.** Text re-renders crisp on the new display, and
      matches a window opened fresh there (⌘N on that display). Drag it back and check
      the same in reverse.
- [ ] **The scale change doesn't animate.** The re-render snaps. A visible zoom/scale
      tween on arrival means the `CATransaction` action-disabling regressed.
- [ ] **Panes, drawers, and tool floats all follow.** Split a couple of panes, open a
      drawer and a tool float, then drag: every surface re-renders, not just the focused
      one.

## Cursor shader on unfocused panes (ZEN-237, ZEN-271)

Needs a cursor shader on (Settings → Terminal → Cursor shader → Cursor Warp, the more
visible of the two) and at least two surfaces. It's all GPU output, so no test sees any of
it. ghostty runs the shader's draw timer only while a surface is focused, so a blurred pane
freezes whatever frame it stopped on; ZenTerm stands the shader down to a passthrough while
unfocused so there's nothing to freeze.

The focus libghostty is told about is `paneFocused && isAppActive`, and the host view
reports its window's occlusion, so the draw timer also stops when ZenTerm isn't frontmost
and when the window is covered or minimized (ZEN-271).

- [ ] **A fresh workspace leaves no tracer.** Open a workspace with the bottom and right
      drawers, so they land unfocused while their shells are still starting. No frozen
      smear anywhere in either drawer once the prompts appear. This is the case that
      shipped broken: the shell's first prompt moves the cursor *after* the pane blurred.
- [ ] **Blur mid-smear leaves no tracer.** Move the cursor around a pane, then switch away
      within a fraction of a second. The tail finishes decaying and leaves nothing behind.
- [ ] **Focus doesn't fly a smear in.** Come back to a pane whose cursor moved while it was
      unfocused (let an agent or a build write into it). The cursor is just there, with no
      trail arriving from a stale position. A smear here means the passthrough stand-down
      regressed to removing the shader outright.
- [ ] **Rapid switching stays clean.** Tab between panes quickly for a few seconds. No
      tracer accumulates, and no flicker on the panes being entered or left.
- [ ] **Leaving the app stops the drawing.** Switch to another app with a pane focused.
      GPU time for ZenTerm drops to idle (Activity Monitor's GPU column, or the wattage
      reading in a menu-bar monitor), and coming back leaves no smear flying in.
- [ ] **A covered window stops too.** Stay in ZenTerm and fully cover its window with
      another app's window, or minimize it. Same drop, and no tracer on the way back.
- [ ] **A theme swap lands on a stood-down pane.** With two panes and a shader on, swap
      the theme (`⌘,` → Appearance). The unfocused pane recolors with the focused one
      rather than holding the old theme until you click into it (ZEN-271).

## Palette row reuse and git badges (ZEN-15)

Both palettes now keep a row's view when its identity survives a filter, instead of
rebuilding the list on every keystroke, and the git badges are filled by a background
probe rather than a main-thread `stat`. What's left to look at is what reuse can get
wrong: a row running the wrong entry after the list re-orders, a stale palette after a
theme swap, and a badge that never lands. Needs a `~/.config/zen-term/workspaces` with a
few entries, at least one of them a git repo and one not.

- [ ] **Typing tracks the list.** Open ⌘P, type a query through to nothing and backspace
      all the way out. Rows follow the filter with no duplicates, no gaps, and no row left
      behind at the bottom. Keycaps keep their glyphs (⌘ ⇧ ⌥ ⌃ ⏎), not blank boxes.
- [ ] **Clicking a re-ordered row runs *that* row.** In ⌘P, type something that leaves
      several matches in a different order than the unfiltered list, then click the second
      or third one. It runs the command under the pointer. This is the reuse failure mode
      with teeth: a stale index binding runs a neighbour instead.
- [ ] **⌘⇧P the same.** Filter to re-order the workspaces, click one down the list, and
      the workspace you clicked opens. ⏎ and the arrows agree with the click.
- [ ] **A theme swap repaints the rows.** With a palette reachable, change the theme
      (`⌘,` → Appearance), then reopen ⌘P and ⌘⇧P. Row titles, shortcuts and the ＋ row
      are in the new palette. Rows still in the old colors mean the reuse index survived
      the swap.
- [ ] **Git badges land.** Open ⌘⇧P: repo workspaces show the git mark, plain folders
      don't. It may appear a beat after the card on the first open of a session; on
      later opens it's there immediately.
- [ ] **A new repo shows up without a relaunch.** `git init` one of the plain workspace
      folders, reopen ⌘⇧P, and it now carries a badge. Settings → Workspaces agrees.
- [ ] **⌘⇧P opens in one move.** The `workspaces` file is read off the main thread, so the
      card is built a turn after the press. It must still spring in the way it does on main:
      at full size, with its rows already there. A card that appears small and then grows
      means it went back to presenting before the load landed. Press it repeatedly and
      watch for any size change after the spring starts.
- [ ] **A second press before it appears closes it.** Press ⌘⇧P twice quickly. You get no
      card, not two, and not one you have to dismiss twice.
- [ ] **Settings → Workspaces never flashes its empty state** on the way to showing rows.
- [ ] **Add and edit still catch duplicate names.** From ⌘⇧P's ＋ row, and from
      Settings → Workspaces on an existing row, type the name of a workspace that already
      exists. The form still refuses it. Those cards wait for the file before appearing,
      so a slow disk shows a beat of nothing rather than a form that accepts a duplicate.
- [ ] **Tool floats still gate on git.** Toggle a `git:true` float from a folder outside
      any repo (toast blocks it) and from inside one (it opens). Toggle a plain float:
      it opens with no perceptible delay. Double-press a git-gated float's chord fast:
      one card, never two, and if the second press beats the card it stays closed.
- [ ] **Nothing lands after you've moved on.** A git-gated float's open now resolves a
      beat after the press. Press its chord and immediately switch tabs, and separately
      press it and immediately hit ⌘⇧P. In both cases no float card appears afterwards:
      you get the tab you asked for, or the picker alone with the keyboard in it.

## Settings writes off the main thread (ZEN-17)

Every in-app config write now writes and re-resolves off the main thread and applies on
it. Each of these used to happen inside the keystroke; they now happen a queue hop later,
and a control that repaints from the reloaded config is where that shows. The unit tests
cover where the work runs and that it stays ordered; what they can't check is whether the
result still reads as one movement.

- [ ] **A slider or numeric field still applies live.** Settings (`⌘,`) → Appearance, hold
      an arrow on a numeric field, or retype a value. The window keeps up with the value as
      it settles, and the field holds what you typed. Text snapping back to an older value
      mid-edit means a stale write's refresh landed on the field.
- [ ] **Segmented and dropdown rows don't flick backwards.** Settings → General, click
      Notifications Off then On then Off as fast as you can; same with Appearance → Theme
      through three themes. The control lands on your last pick and never steps back
      through the earlier ones on the way. Only the newest write repaints the rows, and
      this is what that's for.
- [ ] **⌥↑ / ⌥↓ still reorders tool floats.** Settings → Tools, focus a row, ⌥↓ then ⌥↓
      again. The float moves each press and focus rides along with it. The list rebuilds
      after the write lands now, so a float that doesn't move means the rebuild stopped
      waiting for it.
- [ ] **A rebind still says so.** Settings → Keybinds, record a new shortcut. "Shortcut
      saved." appears and the popover closes a beat later. Reset one with Backspace onto a
      chord another action holds: the displaced row still says what it lost and where it
      went.
- [ ] **Saving a tool float still returns to Settings → Tools.** Add, edit, and delete a
      float. Each lands back on the Tools list with the change already in it, and the dock
      button appears or disappears with no relaunch.
- [ ] **⌘⌥R still reloads.** Hand-edit `~/.config/zen-term/config` (change `font-size`),
      press ⌘⌥R, and every window picks it up.
