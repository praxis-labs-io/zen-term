# zen-term — Architecture Plan

## The one decision this document encodes

The chrome is the product. The terminal core is a dependency we refuse to bet the project on.
So everything we build sits **above a single protocol seam** (`TerminalSurface`), and the core
underneath is swappable at will.

- **Start on SwiftTerm** — pure Swift, stable versioned API, plain SPM, no Zig, no unstable C header.
  Deletes the entire Phase 0 risk profile. Ships a real kitty-replacement fast.
- **Swap target is libghostty** — GPU Metal rendering + the custom-shader cursor animation (the one
  thing SwiftTerm can't do). Adopted through the same protocol, so it's a leaf swap, not a rewrite.

The rule that keeps this honest: **if only one backend can do a thing, it stays below the seam.**
The protocol only ever grows to hold what the chrome genuinely needs from _any_ terminal.

---

## The seam — `TerminalKit`

The only thing the chrome ever knows about a terminal. ~60 lines, changes rarely.

```swift
import AppKit

/// Spawn parameters for a terminal-backed leaf.
struct TerminalSurfaceConfig {
    var command: String?                 // nil = user's default shell
    var args: [String] = []
    var workingDirectory: URL?
    var environment: [String: String] = [:]
    var fontSize: CGFloat?
}

struct TerminalNotification { var title: String; var body: String }
struct TerminalProgress {
    enum State { case running, paused, error, indeterminate }
    var state: State
    var fraction: Double?                 // OSC 9;4 → "agent working / waiting"
}

/// Events flowing OUT of a surface, up into the chrome.
/// Each backend translates its native callbacks into these.
protocol TerminalSurfaceDelegate: AnyObject {
    func surface(_ s: TerminalSurface, titleDidChange title: String)
    func surface(_ s: TerminalSurface, cwdDidChange url: URL)                 // OSC 7 / 133
    func surfaceDidRingBell(_ s: TerminalSurface)                            // → toast
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) // OSC 9 / desktop_notification
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?)      // OSC 9;4
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?)
    func surfaceWantsClose(_ s: TerminalSurface)
}

/// The leaf contract. A backend is anything that can BE a terminal inside our chrome.
protocol TerminalSurface: AnyObject {
    var view: NSView { get }             // the chrome places THIS in the Pane tree
    var delegate: TerminalSurfaceDelegate? { get set }
    var title: String { get }
    var isFocused: Bool { get }

    func start(_ config: TerminalSurfaceConfig)
    func focus()
    func terminate()

    // Actions the palette / keybinds route down; backends map to their own verbs.
    func paste(_ text: String)
    func copySelection() -> String?
    func scrollToBottom()
}

/// Swap point. The chrome only ever calls `.make()`.
enum TerminalBackend { case swiftTerm, ghostty }

enum TerminalSurfaceFactory {
    static var backend: TerminalBackend = .swiftTerm   // flip to .ghostty to swap the whole app
    static func make() -> TerminalSurface {
        switch backend {
        case .swiftTerm: return SwiftTermSurface()
        case .ghostty:   return GhosttySurface()
        }
    }
}
```

---

## Backend A — SwiftTerm (starting core)

Native `NSView`, stable API, no build ceremony. Wire its delegates into ours.

```swift
import SwiftTerm

final class SwiftTermSurface: TerminalSurface {
    private let term = LocalProcessTerminalView(frame: .zero)   // macOS local-shell NSView
    weak var delegate: TerminalSurfaceDelegate?

    var view: NSView { term }
    var title: String { term.terminal?.title ?? "" }           // verify accessor vs current API
    var isFocused: Bool { term.window?.firstResponder === term }

    init() {
        term.processDelegate = self          // LocalProcessTerminalViewDelegate
        // TerminalViewDelegate also wired for bell + OSC 9;4 progress
    }

    func start(_ c: TerminalSurfaceConfig) {
        var env = Terminal.getEnvironmentVariables()
        c.environment.forEach { env.append("\($0)=\($1)") }
        term.startProcess(
            executable: c.command ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            args: c.args,
            environment: env,
            currentDirectory: c.workingDirectory?.path   // exposed on recent startProcess
        )
    }

    func focus()       { term.window?.makeFirstResponder(term) }
    func terminate()   { /* SIGHUP / terminate the PTY process */ }
    func paste(_ t: String)          { term.send(txt: t) }
    func copySelection() -> String?  { term.getSelectionAsString() }   // verify accessor
    func scrollToBottom()            { term.scrollToBottom() }         // verify accessor
}

extension SwiftTermSurface: LocalProcessTerminalViewDelegate {
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        delegate?.surfaceDidExit(self, code: exitCode)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let d = directory {                                       // OSC 7 payload → file URL
            let path = d.hasPrefix("file://") ? URL(string: d)?.path ?? d : d
            delegate?.surface(self, cwdDidChange: URL(fileURLWithPath: path))
        }
    }
    func setTerminalTitle(source: TerminalView, title: String) {
        delegate?.surface(self, titleDidChange: title)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    // bell + OSC 9;4 progress → forward via the matching TerminalViewDelegate hooks
}
```

> **Verify against current SwiftTerm docs:** exact names for selection/scroll accessors, the bell
> hook, and the OSC 9;4 progress delegate method. The seam is stable; this conformance is where
> you'll adjust to the real API.

---

## Backend B — libghostty (swap target)

Same protocol. GPU Metal underneath. The shader-driven animated cursor is configured **here** and
never crosses the seam.

```swift
import GhosttyKit

final class GhosttySurface: TerminalSurface {
    private let hostView: NSView          // Metal / IOSurface-backed view Ghostty draws into
    private var surface: ghostty_surface_t?
    weak var delegate: TerminalSurfaceDelegate?

    var view: NSView { hostView }
    // title / isFocused tracked from action_cb + first-responder state

    func start(_ c: TerminalSurfaceConfig) {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        // set nsview pointer, initial command / cwd / env / font-size on cfg
        surface = ghostty_surface_new(App.shared.ghostty, &cfg)
    }
    // input + resize forwarded to the surface; focus via first-responder
}

// The single app-level action_cb routes per-surface actions into the delegate:
//   bell            → surfaceDidRingBell
//   set_title       → surface(_:titleDidChange:)
//   desktop_notif   → surface(_:didPostNotification:)
//   pwd (OSC 7)     → surface(_:cwdDidChange:)
//   OSC 9;4         → surface(_:progressDidChange:)
// The custom-shader cursor animation is configured on THIS surface only.
```

---

## What lives above vs below the seam

**Above (chrome — backend-agnostic, written once, valid for any core):**
Pane tree / splits / gaps / rounded host layers · in-window tab bar (native tabbing disabled) ·
multi-window · bottom + right drawers · lazygit float · command palette · project picker ·
workspace model (cwd + env → `TerminalSurfaceConfig`) · toast system (consumes delegate events).

**Below (backend-specific — swappable, never leaks upward):**
the renderer (CoreText vs Metal) · **custom-shader cursor animation (libghostty only — absent on
SwiftTerm, degrades gracefully)** · kitty-graphics decoding (both have it; surfaces as terminal
content either way) · PTY spawn mechanics · VT parsing · each backend's native callback plumbing.

---

## Repo layout

```
zen-term/
├── vendor/ghostty/                     # submodule → your fork, pinned (only once you add backend B)
├── scripts/build-ghosttykit.sh         # zig build → copies xcframework out
├── Frameworks/GhosttyKit.xcframework    # gitignored build artifact
├── Packages/
│   ├── TerminalKit/                    # the seam + both conformances
│   │   ├── TerminalSurface.swift
│   │   ├── SwiftTermSurface.swift        # depends on SwiftTerm (SPM)
│   │   └── GhosttySurface.swift          # depends on GhosttyKit (added later)
│   └── Chrome/                         # panes, tabs, drawers, floats, palette, toasts
│                                       #   → imports TerminalKit ONLY, never a backend directly
└── ZenTerm.xcodeproj                   # borderless window, entitlements, entry point
```

`Chrome` importing a backend directly is the one thing to lint against — it's how the seam rots.

---

## Phase plan (T-shirt sizes carried over)

| #      | Work                  | Lift                     | Notes                                                                                                                                                                       |
| ------ | --------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **0a** | SwiftTerm leaf spike  | **S** (~a day)           | One `SwiftTermSurface` in a borderless window, live shell, delegate events logging. Proves the seam + chrome spine on a stable base. This is your low-risk Phase 0.         |
| **0b** | libghostty leaf spike | **M**, risk-skewed **L** | `GhosttySurface` on the same protocol. If tractable → selectable backend. If it fights you → wait for the tagged C API. Chrome is already done against the seam either way. |
| **1**  | Panes                 | **M**                    | Recursive split tree, dividers, rounded host layers + gaps, focus routing. End: daily-drivable splits-only terminal.                                                        |
| **2**  | Tabs + windows        | **M** (tabs alone **S**) | In-window tab bar (view swaps), `tabbingMode = .disallowed`, plus real multi-window. End: replaces kitty.                                                                   |
| **3**  | Drawers + float       | **S**                    | Generalize the QuickTerminal pattern into bottom/right drawers + a lazygit float.                                                                                           |
| **4**  | Modern layer          | **M**                    | Palette (S) · workspace/project model (M) · toasts wired to delegate events (S) · cursor shader — ghostty backend only (XS).                                                |

Rolled up: **kitty-replacement (through Phase 2) ≈ L**; **full vision (through Phase 4) ≈ L tipping XL**
once the API-churn tax is folded across the months it spans — and that tax only exists once you're on
backend B.

**The payoff of the seam:** Phases 1–4 are written once, against `TerminalSurface`. Adopting libghostty
is a leaf swap, not a rewrite. That's what turns your one scary phase into two cheap spikes with a
built-in fallback.

---

## Scope discipline — how this stays a side project, not a second gig

This project is doable part-time. It becomes a job only if it drifts past three lines. The build
isn't the risk; **scope creep on a tool you live in 10 hours a day** is. Hold these and it's a
season-long build that ends with you using something you made. Blur any one and it eats your winter.

### Guardrail 1 — Ship for one user: you. Do not release. (one-way door)

Building for your machine, your shell, your config is _bounded_ — one setup to support, forever.
Publishing inherits everyone else's terminals, shells, config permutations, and issues. That is a
different project with a different cost structure. Releasing is allowed — but only as a **separate,
later, deliberate decision**, never a drift. Until then: no README-for-others, no packaging, no
"someone might want this." Tool-for-one.

### Guardrail 2 — libghostty is opt-in with no deadline. Ever.

Backend B is the only genuinely unbounded work here (Zig toolchain, unversioned C API, perpetual
"bump the pin, fix what broke" tax). The seam exists specifically so it stays optional. Rule:
**you may open spike 0b only when tinkering with it is the thing you want to do that day.** The
moment it goes on a timeline or a milestone, you've hired yourself. SwiftTerm is the shipping core;
libghostty is a someday-if-it's-fun experiment behind a one-line flag.

### Guardrail 3 — Stop at "better than kitty for me," not "good."

The last 10% of a daily-driver — focus edge cases, IME/dead keys, mouse reporting in TUIs, resize
races, scrollback feel — is a long tail that can absorb infinite time. You'll feel it more than a
normal side project because it's in your face all day. The exit condition is comparative, not
absolute: the day it beats kitty _for your workflow_, you're done. "Good in general" is not the bar
and is not your job. Also timebox the shader/animation polish — most fun, least necessary.

### Definition of done — "kitty-replacement"

Hard line to stop at. When every box is checked, the project is **finished** for side-project
purposes; everything past it is optional polish you do for fun, not obligation.

- [ ] Live shell in a borderless window, input/resize/focus correct (spike 0a)
- [ ] Splits: create, close, navigate, resize — focus routing correct across all of them
- [ ] In-window tabs (view swaps, native tabbing disabled) + real multi-window under yabai
- [ ] Copy/paste fidelity + scrollback feel you don't notice (i.e. no worse than kitty)
- [ ] Your top-3 daily TUIs run clean: (fill in — e.g. nvim, lazygit, a full-screen pager)
- [ ] You've used it as your only terminal for one full work week without reaching for kitty

That last box is the real gate. If you pass a week without crawling back, ship it _to yourself_ and
call Phases 3–4 dessert.

---

## Standing risks / discipline

- **Keep the seam minimal.** Every protocol method is a promise _both_ backends must keep. When in
  doubt, push capability below the line and expose only its effects (e.g. progress events, not "the
  shader").
- **Intercept global keybinds ahead of the terminal.** A live terminal `NSView` is a first responder
  that greedily consumes every keystroke and forwards it to the PTY. The chrome's global chords
  (`Ctrl+hjkl` nav, `⌘|` split, `⌘B` drawer) must be caught *before* the terminal swallows them — via
  a local key-event monitor / responder-chain interception at the chrome level. This is the single
  fiddliest integration seam, it's chrome-side work, and it's proven in spike 0a rather than
  discovered later.
- **Verify conformances against live APIs.** SwiftTerm and libghostty method signatures both drift;
  the protocol won't.
- **Agent-idle toasts are near-free:** SwiftTerm's OSC 9;4 progress delegate and libghostty's
  `action_cb` both land as the same `progressDidChange` event upstairs.
- **Backend B build cost is deferred, not avoided:** Zig toolchain + xcframework build + pinned fork
  all arrive only when you start spike 0b. Nothing about backend A touches them.
