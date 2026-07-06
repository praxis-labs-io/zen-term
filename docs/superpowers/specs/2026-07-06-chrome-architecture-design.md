# zen-term — Chrome Architecture & v0 Design

_Date: 2026-07-06_

## Thesis

**The chrome is the product. The terminal core is a drop-in leaf dependency.**

Everything we build sits above a single protocol seam (`TerminalSurface`). The
terminal underneath is swappable at will: we start on SwiftTerm (stable Swift
API, plain SPM, no Zig) and keep libghostty as a later opt-in swap. This design
doc governs the _chrome_ — the thing that makes zen-term zen-term. The terminal
is proven once, behind the seam, and then never fought again.

Full backend rationale and the phase economics live in
[`architecture-plan.md`](../../architecture-plan.md). This doc does not
restate them; it specs the build sequence and the v0 (Epic 0) in detail.

## Design reference — the `shell-halo` prototype

The visual and interaction target is the `shell-halo` web prototype
(github.com/Drucial/shell-halo). That repo is a **pixel-and-interaction spec,
not code to port** — it is React/Zustand/Tailwind; our build is native
Swift/AppKit. Every prototype component has a native counterpart in the chrome
layer, and the prototype's split-tree store is effectively the algorithm the
AppKit pane tree implements.

### Visual language

- **Rosé Pine (Moon)** palette — canvas `#232136`, ink `#e0def4`, muted
  `#908caa`, iris accent `#c4a7e7`; the love/gold/rose/pine/foam accents held in
  reserve for state.
- **Floating panes on a padded canvas.** The terminal does not fill the window.
  It sits inset (~16pt) with rounded (~12pt) pane frames, ~8pt gutters between
  splits, and thin (~3pt) dividers that glow iris on hover.
- **The halo = focus.** The focused pane carries an iris ring + soft glow. This
  is the app's signature and its name.
- **Minimal permanent furniture.** A bottom bar: numbered tabs on the left, a
  toggle dock on the right. Everything else — left sidebar, bottom drawer, right
  drawer, lazygit — is a _toggleable overlay_, not fixed chrome.
- Inter for UI text, JetBrains Mono for terminal content.

### Interaction model

- Recursive split tree with **spatial** pane navigation (geometric
  nearest-neighbor by pane center, not tree order).
- **No drag-to-resize in v0.** Splits are created at a fixed ratio; resize
  (drag and/or keyboard) is deferred to a later epic.
- **The keybind map below is provisional and will be reworked in short order** —
  treat specific chords as placeholders, not committed design. What is _not_
  negotiable is the collision rule in the next point.
- **Pane-management chords must not collide with terminal programs.** `Ctrl+hjkl`
  belongs to nvim (and tmux-style navigators) for moving between _their own_
  splits; zen-term must not steal it. zen-term's window/pane chords live on a
  modifier space TUIs don't claim (⌘-based / a dedicated leader), and everything
  the chrome doesn't explicitly reserve passes straight through to the terminal.
  If a chord collides, the zen-term binding moves — not the program's.
- Pane navigation is `⌘h/j/k/l` — deliberately ⌘, not `Ctrl`, so nvim's
  `Ctrl+hjkl` split-nav passes through untouched. Two follow-ups for the rework:
  `⌘H` is macOS "Hide Application" and must be explicitly overridden; and `⌘J`
  now collides with the provisional right-drawer chord below (one moves).
- Other provisional chords (subject to rework): `⌘|` / `⌘-` split · `⌘⇧T` /
  `⌘⇧W` new/close tab · `⌘B` bottom drawer · `⌘J` right drawer _(collides with
  nav-down — will move)_ · `⌘G` lazygit · `⌘W` close pane · `⌘1–9` select tab.

## The seam — `TerminalSurface`

The only thing the chrome ever knows about a terminal. It is defined in full in
`architecture-plan.md` (§ "The seam"). Summary of the contract:

- **`TerminalSurface`** (a backend): exposes an `NSView`, a `delegate`, a
  `title`/`isFocused`, and the verbs `start / focus / terminate / paste /
  copySelection / scrollToBottom`.
- **`TerminalSurfaceDelegate`** (events flowing up): title change, cwd change
  (OSC 7/133), bell, notification (OSC 9), progress (OSC 9;4), exit, wants-close.
- **`TerminalSurfaceConfig`**: command, args, cwd, env, font size.
- **`TerminalSurfaceFactory.make()`**: the single swap point; `backend` flips
  `.swiftTerm ↔ .ghostty`.

The rule that keeps the seam honest: **if only one backend can do a thing, it
stays below the seam** — the protocol only grows to hold what the chrome
genuinely needs from _any_ terminal.

## The one integration asterisk — input & focus routing

The prototype cheats in a way a real terminal cannot: its pane is a `<div>` whose
keystroke handler it owns. A live SwiftTerm view is a first-responder `NSView`
that **greedily consumes every keystroke** and forwards it to the PTY. So the
chrome's own chords (`⌘|`, `⌘B`, …) must be caught _before_ the terminal swallows
them — via a local key-event monitor / responder-chain interception at the chrome
level.

The critical refinement is that this interception is **selective, not
wholesale.** The chrome catches only a small _reserved allowlist_ of chords and
passes everything else straight through to the terminal — because the terminal is
often running a program (nvim, tmux, a pager) that legitimately needs those keys.
`Ctrl+hjkl` is the canonical example: it moves between nvim's own splits and must
reach the PTY untouched. The design rule follows from this: keep zen-term's
reserved set small and on a modifier space TUIs don't claim (⌘ / a leader), so
the passthrough default almost always wins.

This is the single genuinely fiddly seam in the whole project. It is
**chrome-side work, not terminal work**, and Epic 0 validates _both_ halves —
that a reserved chord is caught before the terminal, and that an un-reserved
chord (`Ctrl+hjkl`) passes through — so nothing downstream is built on an
unproven assumption.

## Build sequence (epics)

Terminal-first, chrome-around-it. Each epic after Epic 0 gets its own spec →
plan → implementation cycle.

| Epic | Name | Proves / delivers |
| ---- | ---- | ----------------- |
| **0** | **Borderless terminal PoC** | SwiftTerm can host a live shell in a borderless window; the seam holds; global keybinds can be intercepted ahead of the terminal. **This is the v0 / proof-of-concept.** |
| 1 | Pane canvas + splits + halo | Floating-pane canvas, recursive split tree (fixed ratio, no resize yet), spatial pane nav, the iris focus halo. First daily-drivable splits-only terminal. |
| 2 | Tabs + windows | In-window tab bar (view swaps, native tabbing disabled), `⌘1–9`, real multi-window. Matches the plan's "kitty-replacement" definition-of-done. |
| 3 | Drawers + lazygit float | Left sidebar, bottom drawer, right drawer, lazygit floating overlay, the toggle dock. |
| 4 | Modern layer | Command palette, workspace/project model, toasts wired to delegate events. (Cursor shader is libghostty-only, deferred.) |

Epics 1–4 are written **once**, against `TerminalSurface`. Adopting libghostty
later is a leaf swap, not a rewrite.

## Epic 0 — Borderless terminal PoC (detailed)

**Goal:** a proof that we can put a real, live, borderless-windowed terminal on
screen through the seam — the floor the entire chrome is built on.

**Critical constraint:** the PoC is built _through the seam_, not as throwaway
spike code. Its terminal is `SwiftTermSurface` conforming to `TerminalSurface`,
placed in a bare borderless window. It becomes backend A permanently — the floor
of the app, not scaffolding.

### Scope (in)

1. **`TerminalSurface` protocol + supporting types** — `TerminalSurfaceConfig`,
   `TerminalNotification`, `TerminalProgress`, `TerminalSurfaceDelegate`,
   `TerminalBackend`, `TerminalSurfaceFactory`. Defined once, per the plan.
2. **`SwiftTermSurface`** — conforms to `TerminalSurface`, wraps
   `LocalProcessTerminalView`, maps `LocalProcessTerminalViewDelegate` +
   `TerminalViewDelegate` callbacks into `TerminalSurfaceDelegate`. Method/accessor
   names verified against the live SwiftTerm API (selection, scroll, bell, OSC 9;4).
3. **Minimal-chrome host window** — a titled `NSWindow` with a hidden/transparent
   title bar + `.fullSizeContentView` (traffic lights optionally hidden), _not_ a
   true `.borderless` window (which forfeits free key-window / drag / resize).
   This is the low-effort path to minimal chrome.
4. **Single floating pane** — the host window places `surface.view` inside a
   rounded, bordered pane inset with gutter padding over the Rosé Pine canvas
   (`--canvas` `#232136`). This is the single-pane seed of the canvas that Epic 1
   generalizes into the split tree; it spawns the user's default shell via
   `start(config)`.
5. **Global keybind interception proof** — a local key-event monitor that catches
   one reserved chord (e.g. `⌘W` → close / `⌘K` logged) _before_ the terminal
   consumes it, while an un-reserved chord (`Ctrl+H`) passes through to the PTY —
   proving selective interception (the input-routing asterisk) is solvable.
6. **Delegate events logging** — title / cwd / exit printed to console via the
   reliable `processDelegate` path; a documented spike on whether bell / OSC 9
   notify / OSC 9;4 progress can be surfaced (they live on `TerminalDelegate`,
   below the view delegate), so Epic 4's toast story is de-risked early.

### Not in Epic 0 — deferred to the epics built on top of it

These are **the app** — not cut, just sequenced after the PoC floor is proven.
Epic 0 is deliberately a single floating terminal pane we build everything on:

- Floating-pane canvas, split tree, iris halo, spatial pane nav → **Epic 1**
- Tabs + multi-window → **Epic 2**
- Sidebar, bottom/right drawers, lazygit float, toggle dock → **Epic 3**
- Command palette, workspace model, toasts → **Epic 4**

Genuinely excluded (not merely deferred): a `MockSurface` test double
(unnecessary once the real surface works; revisit only if we want it for
automated tests), and libghostty — `GhosttySurface` is a separate later swap, not
on the v0 path.

### Definition of done

- [ ] Live default shell runs in a minimal-chrome (hidden-titlebar) `NSWindow`,
      inside the rounded/bordered floating pane with gutters over the canvas;
      typing, output, and resize behave; window is key and the terminal is first
      responder.
- [ ] The terminal is reached **only** through `TerminalSurfaceFactory.make()` —
      no chrome code references `SwiftTerm` or `SwiftTermSurface` directly.
- [ ] One reserved chord is intercepted before the terminal swallows it, and an
      un-reserved chord (`Ctrl+H`) reaches the PTY (selective interception proven).
- [ ] Delegate events (title, cwd, exit at minimum) are observed in the console.
- [ ] SwiftTerm accessor/delegate names are verified against the live API, not
      assumed from the plan's sketch. (Done during planning — see the plan.)

### Repo layout introduced

A terminal-native **SwiftPM package** (no `.xcodeproj`) — buildable and runnable
entirely from the shell (`swift build` / `swift run` / `swift test`). It opens in
Xcode any time via `open Package.swift` if a debugger/Instruments session is
wanted; an Xcode wrapper/app-bundle is added only later, when code-signing or
entitlements force it (not on the Epic 0–3 path).

```text
zen-term/
├── Package.swift                     # targets: TerminalKit (lib) + ZenTerm (exe); SwiftTerm dep
├── Sources/
│   ├── TerminalKit/                  # the seam + SwiftTerm conformance (only SwiftTerm consumer)
│   │   ├── TerminalSurface.swift     # protocol + config/delegate/progress types
│   │   ├── TerminalSurfaceFactory.swift
│   │   ├── SwiftTermSurface.swift    # depends on SwiftTerm (SPM)
│   │   └── (OSC7 / EnvBuilder helpers)
│   └── ZenTerm/                      # the app chrome — depends on TerminalKit ONLY
└── Tests/TerminalKitTests/
```

The `ZenTerm` target does not list SwiftTerm as a dependency, so it **cannot**
`import` a backend directly — the seam is enforced at the module level, not just
by convention. That import discipline is the one thing to guard; it is how the
seam rots.

## Open questions to resolve before/inside Epic 0

- Exact live SwiftTerm accessor names for selection, scroll-to-bottom, the bell
  hook, and the OSC 9;4 progress delegate method (the plan flags these "verify").
- Whether OSC 9;4 progress surfaces cleanly from SwiftTerm — it underpins the
  later "agent idle/working" toast; if it does not, that feature is at risk and we
  learn it cheaply here.
- `cwdDidChange` should build its `URL` with `URL(fileURLWithPath:)` (after
  stripping any `file://`), not `URL(string:)`, which silently drops paths with
  spaces.
- The full keybind map is provisional and gets a dedicated rework pass. Its main
  open design question is the reserved-chord namespace: a flat ⌘ set vs a leader
  (`Ctrl+a`-style) prefix, chosen so the reserved set stays small and never
  collides with common TUIs. Epic 0 does not need the final map — only proof that
  selective interception + passthrough works.

---

# Epic charters (1–4)

Charter altitude, not implementation detail: each records its goal, what it
delivers, scope in/out, definition of done, dependencies, and the decisions known
today. The detailed implementation spec for each epic is written just-in-time
when it starts — informed by what the prior epics actually taught us. This is the
north star; it is deliberately not a promise about internals we can't know yet.

The plan's own "kitty-replacement" definition of done spans Epics 1–2 plus the
felt-quality bars (copy/paste fidelity, scrollback feel, top-3 TUIs clean, one
full week as your only terminal). Those acceptance items live in the Epic 1/2
definitions below and are the real gate on "done."

## Epic 1 — Pane canvas + splits + halo

**Goal.** Put the signature look and split-based workflow on top of the proven
surface. End state: a daily-drivable, splits-only terminal that already feels like
zen-term.

**Delivers.** The floating-pane canvas (inset padding, rounded pane frames, gap
gutters over the Rosé Pine canvas); a recursive AppKit split tree (a port of the
prototype's `PaneNode` recursion); fixed-ratio splits; spatial `⌘hjkl`
navigation (geometric nearest-neighbor); the iris focus halo (ring + soft glow
tracking focus); focus routing across panes; per-leaf surface lifecycle — each
leaf is a real independent shell built via `TerminalSurfaceFactory.make()`.

**In.** Split create / close / navigate; focus routing; the halo; canvas styling;
the host layer that wraps each `surface.view` and draws the frame + halo (terminal
content is drawn by the backend, the frame is chrome).

**Out.** Drag/keyboard resize (deferred — fixed ratio only); tabs; drawers;
palette.

**Definition of done.** Create, close, and navigate splits with focus routing
correct across all of them; the halo always marks the focused pane; every pane is
an independent live shell; splitting/closing never orphans a running process; it
visually matches the prototype. (Feeds the plan DoD: "splits — focus routing
correct.")

**Depends on.** Epic 0 (surface + selective key interception + delegate events).

**Key decisions / open questions.** How the AppKit hierarchy hosts multiple
`LocalProcessTerminalView`s without focus contention; halo via layer shadow vs
inset border vs both; minimum pane size before a split is refused; whether the
split-tree state lives in a plain model type mirroring the prototype store.

## Epic 2 — Tabs + windows

**Goal.** Become a full daily-driver surface — the point where zen-term replaces
kitty.

**Delivers.** In-window tab bar (numbered, bottom-left, per the prototype), view
swaps between per-tab pane trees, `tabbingMode = .disallowed` to kill native
tabbing, `⌘1–9` + new/close tab, and real multi-window (each `NSWindow` its own
independent tab set).

**In.** Tab model (each tab owns a pane tree + its own focus); the tab-bar UI;
multi-window; disabling native tabs.

**Out.** Drawers; palette; workspace model.

**Definition of done.** Tabs create / close / switch with each tab's pane tree and
focus preserved; **background-tab shells keep running when their tab is inactive**
(view detached, process alive); native tabbing is disabled; multi-window behaves
under yabai. (Feeds the plan DoD: "in-window tabs + real multi-window under
yabai.")

**Depends on.** Epic 1 (the per-tab pane tree it multiplies).

**Key decisions / open questions.** The load-bearing one: keep every tab's view
mounted-but-hidden vs detach/reattach on switch — either way the *process* must
stay alive, so this is about view lifecycle, not shell lifecycle. Also: window
state restoration on relaunch; whether tab titles follow the focused pane's OSC
title.

## Epic 3 — Drawers + lazygit float

**Goal.** Generalize the QuickTerminal pattern into the toggleable overlay layer
from the prototype.

**Delivers.** Left sidebar, bottom drawer (`⌘B`), right drawer (`⌘J`), a lazygit
floating overlay (`⌘G`), and the bottom-right toggle dock reflecting overlay
state. Drawer contents that are terminals are just more `TerminalSurface`s;
lazygit is a surface running `lazygit`.

**In.** Drawer toggle / show-hide animation / sizing (with the prototype's
min/max clamps); the lazygit float and its lifecycle; the toggle dock UI.

**Out.** Palette; workspace model; toasts.

**Definition of done.** Each overlay toggles, is sized within its clamps, and (for
terminal-backed drawers) hosts a live shell; the lazygit float launches `lazygit`
in the right cwd and dismisses cleanly; the toggle dock mirrors current state.

**Depends on.** Epic 0 (surfaces for drawer/lazygit contents); Epic 1 (canvas &
layout); Epic 2 (scoping decision below).

**Key decisions / open questions.** Are drawers **per-window/global or per-tab**?
(The prototype models them per-tab-adjacent but toggled globally.) Does the
lazygit float inherit the focused pane's cwd? Sizing persistence across launches.

## Epic 4 — Modern layer

**Goal.** The "modern terminal" niceties that sit above a solid daily driver.

**Delivers.** A command palette (fuzzy actions + project open); a workspace /
project model (cwd + env → `TerminalSurfaceConfig`, a project picker); a toast
system consuming delegate events (bell → toast, OSC 9 notification → toast, OSC
9;4 progress → the "agent working / idle" signal). The custom-shader cursor
animation is **libghostty-only and stays deferred** — it is configured below the
seam on the ghostty backend and never blocks this epic.

**In.** Palette + its action/project registry; the workspace model and picker;
the toast system wired to `TerminalSurfaceDelegate` events.

**Out.** The cursor shader (deferred, backend-B-only); anything requiring
libghostty.

**Definition of done.** The palette runs actions and opens projects; new
terminals spawn with the selected project's cwd/env; toasts fire correctly on
bell, notification, and progress events — including the agent idle/working toast,
whose viability was proven back in Epic 0.

**Depends on.** All prior epics; the toast system specifically depends on the
delegate events (especially OSC 9;4) validated in Epic 0.

**Key decisions / open questions.** Palette command-registry shape; workspace
persistence and where project definitions live; toast placement and stacking;
whether the agent-progress toast is per-pane or global.
