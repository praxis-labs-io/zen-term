# libghostty backend (ZEN-40 spike → ZEN-45 default)

Stands up `GhosttySurface` on the existing `TerminalSurface` seam: live shells in every
pane type rendered by libghostty's Metal renderer. This started as the "backend B" proof
from `architecture-plan.md` (ZEN-40) — a leaf swap, not a rewrite.

**Status:** the default backend (ZEN-45). The spike's load-bearing hacks are unwound:
resources are staged from the pinned submodule build (no Ghostty.app dependency), the
chrome's `TerminalTheme` drives a generated ghostty config (no in-repo config file, no
`~/.config/ghostty`), spawn args are shell-quoted, and the SwiftTerm backend's parity
features (isBusy close-confirm, Shift+Enter soft newline, desktop notifications, OSC 9;4
progress) are wired. SwiftTerm remains the escape hatch.

## Run it

```sh
bin/build-ghosttykit    # one-time: inits the ghostty submodule + builds xcframework + resources
bin/run                 # libghostty backend (default)
bin/run --swiftterm     # SwiftTerm backend (escape hatch)
```

`GHOSTTY_LOG=stderr bin/run` surfaces libghostty's own logs (off by default in
the embedded lib).

## What the build takes

libghostty ships **no** reusable artifact — the released Ghostty.app statically links it
into its main binary, with no `GhosttyKit.xcframework` or `ghostty.h` exposed. So we build
it from the pinned `vendor/ghostty` submodule (v1.3.1) — the same "build from source, commit
no binary" model ghostty's own macOS app uses (its `macos/.gitignore` ignores the
xcframework too). Two hurdles, both one-time and scripted:

- **Zig 0.15.2 exactly.** Homebrew tracks a newer Zig whose stdlib won't compile ghostty
  v1.3.1. `bin/build-ghosttykit` fetches the pinned toolchain locally.
- **Metal toolchain.** Xcode 26 ships the `metal` shader compiler as a separate download:
  `xcodebuild -downloadComponent MetalToolchain` (~700 MB). Without it the xcframework
  build fails at the `Ghostty.metallib` step.

Output: `Frameworks/GhosttyKit.xcframework` (~135 MB static lib, macos-arm64) plus the
staged runtime resources (`Sources/TerminalKit/Resources/ghostty-resources/` —
shell-integration, themes, terminfo, bundled via SwiftPM) — both gitignored and rebuilt
from the submodule, never committed. **CI** builds them the same way and caches them
keyed on the ghostty pin, so only a ghostty bump pays the rebuild; every other run
restores them in seconds. Self-contained: the source pin is a committed submodule,
nothing is fetched as a prebuilt binary.

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

## Known limitations

- **IME / dead-key composition** is not wired (no `NSTextInputClient`). Basic typing,
  control chars, arrows, and shortcuts work; multi-keystroke composition does not.
- **Scroll momentum** phases are omitted (precision flag only).
- **GPU cursor shader — explored and removed.** A cursor-trail shader rendered correctly, but
  *any* custom shader routes ghostty through an intermediate-texture post-process pass that
  flashes white during TUI transitions (prompt → fzf/nvim) in this transparent-window embed —
  independent of `custom-shader-animation`. No custom shader = no flash. So the GPU cursor
  animation and flash-free transitions are mutually exclusive until the transparent-window
  compositing is solved (opaque custom-shader screen texture, or an opaque window). Removed for
  now; tracked in ZEN-68.
- **Focus-on-click** is reported to the chrome, but full focus-follows and overlay
  occlusion parity with SwiftTerm isn't done.
- **Two ImGui link warnings** (`_ImFontConfig_ImFontConfig`, `_ImGuiStyle_ImGuiStyle`) —
  ghostty's optional inspector, unused here; harmless.
- **`ghostty_surface_new` can fail with `error.OutOfMemory` under cross-process
  WindowServer pressure.** Not GPU memory (Metal allocates 2K textures fine with 18 GB free)
  and not a specific shader — it reproduces once enough short-lived GUI instances have been
  launched and SIGKILL'd, leaving WindowServer surfaces uncollected. A fresh graphics
  session (log out/in) clears it. **In-app churn is verified clean (ZEN-45):** the
  `GhosttySurfaceChurnTests` stress harness (`ZENTERM_CHURN_STRESS=1`) ran 500
  create/attach/destroy cycles in one process with zero surface-creation failures and a
  plateauing footprint (+55 MB @ 150 → +64 MB @ 500 — caches, not a per-surface leak).
  `ghostty_surface_free` releases the hosted layer/IOSurface correctly; the failure mode
  is a dev-loop artifact (killed processes), not something zen-term's pane churn can hit.

None of these are seam problems — they're all below it, exactly where backend-specific work
is supposed to live. libghostty is now the default backend (ZEN-45); SwiftTerm remains the
escape hatch (`ZENTERM_BACKEND=swiftterm`). The remaining gaps above are tracked in ZEN-67
(IME), ZEN-68 (shaders + scroll), and ZEN-69 (input + busy parity).
