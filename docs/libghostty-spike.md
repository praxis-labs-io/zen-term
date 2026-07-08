# libghostty backend spike (ZEN-40)

Stands up one `GhosttySurface` on the existing `TerminalSurface` seam: a live shell in a
borderless pane rendered by libghostty's Metal renderer, behind a backend flag, with
SwiftTerm untouched as the default. This is the "backend B" proof from
`architecture-plan.md` — a leaf swap, not a rewrite.

**Status:** works. `ghostty_surface_new` succeeds, the Metal renderer initializes, and a
real `login → zsh` PTY spawns and renders. The chrome (panes, tabs, drawers, palette) is
unchanged — it only ever talks to the seam.

## Run it

```sh
bin/build-ghosttykit                 # one-time: builds Frameworks/GhosttyKit.xcframework
swift build
ZENTERM_BACKEND=ghostty swift run ZenTerm   # libghostty backend
swift run ZenTerm                            # SwiftTerm backend (default, unchanged)
```

`GHOSTTY_LOG=stderr` surfaces libghostty's own logs (off by default in the embedded lib).

## What the build takes

libghostty ships **no** reusable artifact — the released Ghostty.app statically links it
into its main binary, with no `GhosttyKit.xcframework` or `ghostty.h` exposed. So we build
it from source. Two hurdles, both one-time and scripted:

- **Zig 0.15.2 exactly.** Homebrew tracks a newer Zig whose stdlib won't compile ghostty
  v1.3.1. `build-ghosttykit.sh` fetches the pinned toolchain locally.
- **Metal toolchain.** Xcode 26 ships the `metal` shader compiler as a separate download:
  `xcodebuild -downloadComponent MetalToolchain` (~700 MB). Without it the xcframework
  build fails at the `Ghostty.metallib` step.

Output: `Frameworks/GhosttyKit.xcframework` (~135 MB static lib, macos-arm64). Gitignored
alongside `vendor/` — rebuilt per machine, never committed.

## How it maps to the seam

libghostty is a much heavier embedding contract than SwiftTerm's drop-in `NSView`:

- **`GhosttyApp`** — the process-global `ghostty_app_t` (libghostty allows exactly one).
  Owns the runtime callbacks and pumps the event loop: libghostty calls `wakeup_cb` from
  any thread, we hop to main and `ghostty_app_tick`. Inbound actions (title / pwd / bell /
  child-exit) route to the right surface via its `userdata` pointer and out through the
  `TerminalSurfaceDelegate` — the same events SwiftTerm emits.
- **`GhosttyHostView`** — the `NSView` libghostty attaches its Metal layer to (it makes the
  view layer-hosting itself, so we must *not* set `wantsLayer`). Forwards every input —
  key, text, mouse, scroll, focus, size, content-scale — since, unlike SwiftTerm, nothing
  is handled for us. Key/mods translation is ported from Ghostty's own `NSEvent` helpers.
- **`GhosttySurface`** — the `TerminalSurface` conformance. Creates the surface, wires the
  delegate, implements paste / copy / scroll against the C API.

Only `TerminalKit` links `GhosttyKit`; the chrome (`ZenTerm`) imports `TerminalKit` only,
so the seam holds. The backend is selected once at startup by `TerminalSurfaceFactory`.

## The transparent-window compositing gotcha (fixed)

Heavy TUI redraws (nvim, fzf) tore and flashed a light block. Cause: zen-term's window
is transparent (`isOpaque = false`) for the vibrancy backdrop, so the compositor blended
ghostty's Metal layer against that backdrop every frame and redraw gaps showed it through.
SwiftTerm never hit this — it draws opaquely on the CPU. Fix: after `ghostty_surface_new`,
mark the now-hosted layer opaque over the terminal background
(`hostView.layer.isOpaque = true` + `backgroundColor`). It then composites as a solid
surface — no per-frame blend, no flash. This is the kind of integration detail a GPU
backend needs that a CPU one doesn't.

## Known limitations (spike scope)

- **IME / dead-key composition** is not wired (no `NSTextInputClient`). Basic typing,
  control chars, arrows, and shortcuts work; multi-keystroke composition does not.
- **Scroll momentum** phases are omitted (precision flag only).
- **Theme / font aren't plumbed through `TerminalSurfaceConfig`** — libghostty reads its
  own config, so the spike applies Rosé Pine Moon + JetBrainsMono via an in-repo config
  (`config/ghostty/`, pointed at Ghostty.app's resources) rather than the seam. Making the
  seam's theme/font drive libghostty is follow-up work.
- **GPU cursor shader — explored and removed.** A cursor-trail shader rendered correctly, but
  *any* custom shader routes ghostty through an intermediate-texture post-process pass that
  flashes white during TUI transitions (prompt → fzf/nvim) in this transparent-window embed —
  independent of `custom-shader-animation`. No custom shader = no flash. So the GPU cursor
  animation and flash-free transitions are mutually exclusive until the transparent-window
  compositing is solved (opaque custom-shader screen texture, or an opaque window). Removed for
  now; revisit under ZEN-45.
- **Focus-on-click** is reported to the chrome, but full focus-follows and overlay
  occlusion parity with SwiftTerm isn't done.
- **Two ImGui link warnings** (`_ImFontConfig_ImFontConfig`, `_ImGuiStyle_ImGuiStyle`) —
  ghostty's optional inspector, unused here; harmless.
- **`ghostty_surface_new` can fail with `error.OutOfMemory` under surface/window
  resource pressure.** Not GPU memory (Metal allocates 2K textures fine with 18 GB free) and
  not a specific shader — it reproduces even with no custom shader once enough short-lived
  GUI instances have been launched and SIGKILL'd, leaving WindowServer surfaces uncollected.
  A fresh graphics session (log out/in) clears it. This is the biggest open robustness
  question for the backend: rapid pane create/destroy needs a clean teardown path (verify
  `ghostty_surface_free` fully releases the hosted layer/IOSurface) before it's daily-driver
  solid. Tracked as follow-up.

None of these are seam problems — they're all below it, exactly where backend-specific work
is supposed to live. Per Guardrail 2, this stays behind the flag with no deadline;
SwiftTerm remains the shipping core.
