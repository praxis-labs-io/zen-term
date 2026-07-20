# iOS companion app: remote view + control of a live terminal surface

Idea capture from a brainstorm. Not scoped for pickup yet, and not an active
epic. Goal: an iOS app that connects to a running Mac instance of ZenTerm to
view and drive a live terminal surface from a phone.

This file is a captured idea, not durable architecture. If the idea graduates,
promote it into a Linear project with PR-sized tickets and delete this file.

## Framing

An iOS app can't *be* ZenTerm. The app is AppKit + libghostty rendering locally
into `NSView`s, and the `TerminalSurface` seam is an `NSView` contract, so
nothing crosses to iOS directly. The iOS app is a **remote client**: the Mac
keeps hosting the shells and rendering; the phone drives it and views it over
the network.

The existing precedent is `NavSocketServer` (`Sources/ZenTerm/NavSocketServer.swift`)
plus `docs/nvim-navigator-protocol.md`: a small, backend-agnostic external-control
server (AF_UNIX socket, newline-delimited JSON, decode, hop each command to the
main actor via `apply`). A companion generalizes that shape onto a network
transport with a richer command set.

## Two halves, very different sizes

### 1. Control (send input): feasible today, no ghostty changes

Every input class already has a C entry point the app calls:

- Text: `ghostty_surface_text` (used by `paste()`)
- Real key events: `ghostty_surface_key` (+ mods, IME preedit)
- Mouse: `ghostty_surface_mouse_button` / `_mouse_pos` / `_mouse_scroll`
- Any named ghostty action by string: `ghostty_surface_binding_action(ptr,
  "scroll_to_bottom", ...)` (used by `scrollToBottom()`). This triggers *any*
  ghostty keybind action, so a phone can drive scroll, select-all, clears,
  prompt jumps, and so on without wiring each one.

A network client marshals these on the main thread (the same hop
`NavSocketServer.apply` already does).

### 2. View (read the screen out): this is where the real work is

What exists in libghostty v1.3.1 (pinned `vendor/ghostty`):

- `ghostty_surface_has_selection` + `ghostty_surface_read_selection`: current
  selection as text.
- `ghostty_surface_read_text(surface, Selection, *Text)`: **arbitrary-region
  plain text** (the app doesn't currently use this). `Selection` is
  `{ tl: Point, br: Point, rectangle }`. The header warns it is expensive; cache
  and throttle.

So a **plain-text** remote view is buildable today with zero ghostty changes,
just by wiring up `read_text`. What's missing is a **styled** grid (color,
cursor, attributes) and an efficient **dirty-diff** stream. There is no
`read_grid`-style export at this version.

## Building our own API (we have full ghostty source, MIT)

The hard part already exists internally:

- `src/terminal/render.zig` defines `RenderState`. It is renderer-agnostic (its
  own note: "this is in src/terminal and not src/renderer because the goal is
  that this remains generic to multiple renderers ... can aid libghostty-vt with
  converting terminal state to a renderable form") and **dirty-tracked** (only
  re-renders dirty regions between `update` calls). The Metal renderer already
  consumes it.
- `Cell` is a clean `packed struct(u64)` (codepoint / palette / rgb, `style_id`,
  `wide`, `semantic_content`, `hyperlink`). `Style` is fg/bg/underline color plus
  a 16-bit flags struct, resolved via a style map.
- Ghostty is **already factoring the VT engine into a standalone C library**:
  `src/lib_vt.zig`, `src/lib/` C-binding scaffold, `src/main_c.zig`, a `lib-vt`
  build step.

So "our own API" is a thin **export layer over machinery that already exists**,
not new terminal-engine work. Concretely, new `export fn ghostty_surface_*` in
`src/apprt/embedded.zig` alongside the roughly 40 already there:

1. `ghostty_surface_read_grid(surface, *GridSnapshot)`: project `RenderState`
   across the C ABI (rows/cols, cursor pos/shape, flat cell array with resolved
   fg/bg/flags + wide/semantic). Mirror the existing `read_text` -> `Text` ->
   `free_text` lifecycle.
2. `ghostty_surface_read_grid_dirty(...)`: only dirty rows since last call, for a
   tiny diff stream instead of full frames. `RenderState` already tracks this.
3. Optional callback/subscribe variant so frames push on change rather than
   polling.

### Build paths

- **Patch the pinned fork (fastest, fits today's setup).** `bin/build-ghosttykit`
  already builds `GhosttyKit.xcframework` from the `vendor/ghostty` submodule
  (v1.3.1). Add exports to `embedded.zig` + `include/ghostty.h`; they show up as
  `ghostty_surface_*` like every other symbol. No change to how ZenTerm links.
- **Ride `libghostty-vt`.** Cleaner boundary, longer horizon, mid-flight
  upstream.

### Hard parts / real costs

- **Threading.** `read_selection` / `read_text` both take
  `core_surface.renderer_state.mutex`; the header warns `read_text` is expensive.
  A grid export locks the same mutex the renderer and PTY IO contend on: hold it
  too long or too often and you stall redraw or IO. The dirty-diff path is what
  keeps this cheap; a naive full-grid poll is the trap.
- **Color resolution.** Cells carry `style_id` and colors can be palette indices;
  a faithful snapshot resolves against the active palette/theme (resolve to RGB
  in the export, or ship palette refs + the palette).
- **Edge cases:** wide chars + spacers, grapheme clusters, hyperlinks (ID -> map
  lookup), kitty-graphics images (not text), cursor visibility/shape. A v1 can
  punt on images and hyperlinks.
- **Fork maintenance.** A Zig patch in a vendored submodule is a new competency
  next to the Swift chrome, and we own rebasing it across ghostty bumps. Keep the
  diff small and additive (export fns only) so it rebases cleanly. Licensing is
  fine (ghostty core is MIT; this doesn't touch the LGPL/libintl handling
  `build-ghosttykit` already does).

## Transport & security (dominant cost regardless of view fidelity)

Everything today is same-machine (AF_UNIX). A phone is a different device:

- Discovery + transport: Bonjour on LAN, or a relay for off-LAN.
- **Pairing + auth is not optional.** A companion that sends keystrokes to
  someone's shell over the network is a remote-code-execution surface pointed at
  their machine. Device pairing, encryption, and per-session tokens come first,
  before any UI.

## Seam rule

Per project rules, the C export and any pixel/frame capture live **below** the
seam in `TerminalKit`. The seam grows a neutral snapshot / frame-stream type; the
chrome (`Sources/ZenTerm/`) never learns it came from libghostty. It is
backend-agnostic in principle (any terminal takes keys and produces a screen), so
it is legitimate seam growth.

## Rough effort shape

- Plain-text remote view, today, no ghostty patch (wire up `read_text`): days.
- Styled grid + dirty-diff via new exports: the export layer is small (the engine
  is done); real time goes to threading discipline, color resolution, and
  standing up the Zig build/rebase workflow. Call it a couple-week spike to a
  solid styled, diffed stream. The expensive-forever part is carrying the fork,
  not writing it.
- Networking + pairing + security: the real weight of the project regardless of
  the above.

## Suggested first step if promoted

Control-only companion over Bonjour + a paired, encrypted channel, reusing the
chrome's existing command dispatch (`WindowController.handle` / `CommandCatalog`)
to prove transport + pairing on the small surface. Text-view via `read_text` as
an easy add. Treat the styled-grid ghostty API as a separate, later epic that
stands or falls on the fork workflow.

## Alternative to the custom API

Pixel mirror: libghostty renders into a Metal layer on `hostView.layer`. Capture
the view/layer (ScreenCaptureKit / Metal readback) and stream frames.
Content-complete (colors, cursor, TUIs, images) but it is video: bandwidth +
encode, and input coordinates must map back. A robust "see exactly what's on
screen" path that needs no ghostty patch, at the cost of not being the
lightweight structured stream.
