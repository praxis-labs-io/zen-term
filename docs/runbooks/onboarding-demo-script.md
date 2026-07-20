# Onboarding demo script

What to drive during a live onboarding session. The onboarding pack
(`docs/onboarding.md`) is what they keep afterward. This is what you say.

Ordered so each beat sets up the next. About 15 minutes without questions.

---

## Before they arrive

- [ ] One window, two or three tabs at most. A wall of tabs reads as clutter.
- [ ] Workspaces already configured, so ⌘⇧P has something in it. A fresh install
      shows an empty picker, and demoing that sells nothing.
- [ ] At least one tool float bound, ⌘G to lazygit.
- [ ] Notifications quiet, except the one you plan to demo.
- [ ] A repo with real, uncommitted changes, so lazygit has something to show.
- [ ] Font installed, theme set.
- [ ] Know your version. Press ⌘, and read the footer.

---

## 1. The hook (30 seconds, before touching a key)

> "Ghostty renders the text and runs the shell. This is the app around it."

Say what it is, then stop talking and split a pane. Do not explain the
architecture. Nobody is here for the seam.

## 2. Panes and the halo (⌘⇧\, ⌘⇧-)

Split side by side, then split again top and bottom. Let them watch the halo
follow focus.

This is the signature look and it lands in three seconds without narration. Let
the animation finish before you say anything.

## 3. Navigation (⌘H ⌘J ⌘K ⌘L)

Move around the panes you made.

> "Vim's arrow keys. Your hands never leave home row."

If they don't know vim: H left, L right, J down, K up. Say it once, move on. Do
not teach vim.

## 4. Focus Mode (⌘F)

Focus a pane to fill the window, then exit Focus Mode.

> "Same panes, one gets the room."

## 5. Drawers (⌘B, ⌘\)

Open the bottom drawer, then the right one. This is the beat where the layout
stops looking like a terminal and starts looking like an app.

## 6. The command palette (⌘P)

> "If you forget any of this, it's all in here."

Type a couple of letters and run something. Point out that each row lists its
shortcut. This is the beat that makes the other shortcuts optional, so it
matters more than any single chord.

## 7. Workspaces (⌘⇧P)

The payoff beat. Open a workspace and let them watch the tab arrive already
arranged: named after the workspace, in the right folder, editor and agent in
place.

> "A folder, plus the layout I want when I open it. One keystroke."

Then show where they come from: ⌘, then Workspaces, then ＋ Add workspace. It
matters that they see it is a form and not a config file.

## 8. Tool floats (⌘G)

Float lazygit, do something small in it, close it. Reopen it to show it is
instant the second time.

> "Any command, any shortcut. Mine is lazygit. Yours might be btop or a dev
> server."

Then show ⌘, then Tools, so they see it is the same kind of form.

## 9. The agent beat

Only if it triggers cleanly. Have an agent in a background tab ask for
permission and let the tab signal fire.

> "It tells you which tab wants you."

This is the beat that lands hardest with people running agents, and it is the
easiest to fumble live. If it does not fire in five seconds, move on. Do not
debug in front of them.

## 10. Themes (⌘, then Appearance)

Switch themes once. It recolors the whole app, not only the terminal text.

Do this last. It is the beat people want to play with, and if you open it early
you lose the room to it.

---

## Where to stop

Do not show or promise:

- The web pane spike (ZEN-73), the Linear and GitHub integrations (ZEN-31), or
  anything else on the board. A roadmap in the present tense is a lie you have
  to walk back.
- The seam, the backend swap, or the architecture, unless they ask twice.

## Landmines

- **Do not plain-click a link** and expect it to open. Hold ⌘. If you forget in
  front of them you will look like you found a bug in your own app.
- **Do not open a fresh install's ⌘⇧P.** It is empty except for ＋ Add workspace.

## The ask

Close by telling them what you want back:

> "Use it for a week as your only terminal. When something is broken or awkward,
> tell me. Awkward counts. Include the version from ⌘, and don't polish it."

Then send them `docs/onboarding.md` and the DMG link.
