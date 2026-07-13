# v0 Launch — Manual Verification Runbook

Manual checks for behavior with **no automated coverage** — the GUI/IME/OS-integration
paths a unit test can't reach (tool-shell TCC blocks screenshots + synthetic keystrokes,
so these are driven by hand on a Mac via `swift run ZenTerm`). Run this pass before
tagging v0.

## Input method (IME) & dead keys — ghostty backend

The ghostty IME path (`GhosttyHostViewIME` preedit state machine) has **zero automated
coverage**. Verify by hand:

- [ ] **Option dead keys.** Type `⌥e` then `e` → `é`. Type `⌥u` then `u` → `ü`. Type
      `⌥e` then space → a bare `´`. The preedit accent should render underlined, then
      resolve on the second keystroke — no doubled or dropped characters.
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
