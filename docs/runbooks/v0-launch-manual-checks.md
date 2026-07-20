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
