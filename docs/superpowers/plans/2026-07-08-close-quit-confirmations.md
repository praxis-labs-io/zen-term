# Close & Quit Confirmations — Implementation Plan (ZEN-49)

> **For agentic workers:** execute task-by-task; each task ends green on
> `bin/check` (build + `swift test` + `swift format lint --strict` +
> `swiftlint --strict`). AppKit wiring with no unit seam is verified by the
> manual runbook at the end, per `CLAUDE.md`.

**Goal:** Guard destructive close gestures with a blocking modal confirmation
built on the ZEN-48 toast infra — ⌘W (per-tab) and ⌘Q (app quit).

**Architecture:** Extend `ToastView`/`ToastPresenter` with an actions row + a
sticky (no-auto-dismiss) mode and a themed `ToastButton`; add a below-the-seam
`TerminalSurface.isBusy`; gate the confirm through the same modal-chord pattern
`WindowController` already uses for the lazygit float; drive ⌘Q through
`AppDelegate.applicationShouldTerminate`.

**Tech stack:** Swift + AppKit + SwiftPM. Targets: `TerminalKit` (seam +
backend), `PaneKit` (pure tree/registry), `ZenTerm` (chrome).

## Context

ZEN-48 (merged) added the toast infra and lazygit persistence. ⌘W currently
closes the focused pane and cascades to closing the tab with **no confirmation**
(`WindowController.handle` `.closePane` → `active?.closeFocused() == false` →
`closeTab`). ⌘Q terminates **immediately** (MainMenu Quit → `terminate:`; there
is no `applicationShouldTerminate`). This plan adds a blocking confirm before
either destroys work. Design source of truth:
`docs/superpowers/specs/2026-07-08-close-quit-confirmations-design.md`.

## Global Constraints

- `Sources/ZenTerm/` must **never** `import SwiftTerm`; backend-specific logic
  (the busy probe) stays in `TerminalKit`, below the seam.
- No `TODO`/`FIXME`/`HACK`; no force-unwrap except documented AppKit.
- One primary type per file; filename matches the type; PascalCase types.
- Confirm copy is final (from the approved spec): ⌘W last-pane → *"Close tab?"* /
  *"This closes the tab."*; ⌘W busy non-last → *"Close pane?"* / *"A process is
  still running here."*; ⌘Q → *"Quit ZenTerm?"* / *"N tab(s) in M windows will
  close."* (drop the window clause when M == 1). Confirming verb button: **Close**
  / **Quit** (destructive kind); the other button is **Cancel**.
- Destructive tint = Rosé Pine Moon `love` `0xeb6f92`; advisory/warning icon tint
  = existing `ToastPresenter.warning` gold `0xf6c177`.

---

## Task 1 — `TerminalSurface.isBusy` + `ProcessProbe` (below the seam)

**Files:**
- Create: `Sources/TerminalKit/ProcessProbe.swift`
- Create: `Tests/TerminalKitTests/ProcessProbeTests.swift`
- Modify: `Sources/TerminalKit/TerminalSurface.swift` (protocol + default extension)
- Modify: `Sources/TerminalKit/SwiftTermSurface.swift` (implement `isBusy`)

**Produces:** `TerminalSurface.isBusy: Bool` (default `false`);
`ProcessProbe.hasChildren(_ pid: pid_t) -> Bool`.

**`ProcessProbe`:** the shell running a foreground command (or a backgrounded
job) has ≥1 child process. `proc_listchildpids` writes whole `pid_t` values up to
the buffer capacity and returns the byte count; a 1-slot buffer therefore returns
`>0` iff the shell has any child.

```swift
import Darwin

/// Kernel probe for "does this process have children" — used to tell a shell
/// running a foreground command (or a backgrounded job) from an idle prompt.
/// Backend-agnostic and pid-only, so it stays below the terminal seam.
public enum ProcessProbe {
    /// True when `pid` has at least one child process. `pid <= 0` → false.
    public static func hasChildren(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var slot = pid_t(0)
        let size = Int32(MemoryLayout<pid_t>.size)
        let filled = proc_listchildpids(pid, &slot, size)
        return filled > 0
    }
}
```

**Seam additions — `TerminalSurface.swift`:** add to the protocol and give it a
default so backends that can't answer inherit "not busy":

```swift
public protocol TerminalSurface: AnyObject {
    // …existing members…

    /// Whether the surface's shell has a running foreground command or a
    /// backgrounded job. Lets the chrome warn before closing live work.
    var isBusy: Bool { get }
}

public extension TerminalSurface {
    // …existing currentDirectory default…

    /// Backends that can't inspect the child process report "not busy".
    var isBusy: Bool { false }
}
```

**`SwiftTermSurface.swift`** — reuse the already-resolved shell pid (same source
as `currentDirectory`):

```swift
public var isBusy: Bool {
    ProcessProbe.hasChildren(term.process?.shellPid ?? 0)
}
```

**Tests — `ProcessProbeTests.swift`** (Foundation `Process`; deterministic):

```swift
import Foundation
import XCTest

@testable import TerminalKit

final class ProcessProbeTests: XCTestCase {
    func test_nonPositivePid_isNotBusy() {
        XCTAssertFalse(ProcessProbe.hasChildren(0))
        XCTAssertFalse(ProcessProbe.hasChildren(-1))
    }

    func test_processWithLiveChild_hasChildren() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(ProcessProbe.hasChildren(selfPid))
    }

    func test_leafChildProcess_hasNoChildrenOfItsOwn() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        XCTAssertFalse(ProcessProbe.hasChildren(child.processIdentifier))
    }
}
```

**Steps:** ① write the tests; ② `swift test --filter ProcessProbeTests` → fails
(no `ProcessProbe`); ③ add `ProcessProbe.swift`, the protocol member + default,
and the `SwiftTermSurface` impl; ④ `swift test --filter ProcessProbeTests` →
passes; ⑤ `bin/check`; ⑥ commit `feat(seam): add TerminalSurface.isBusy via
ProcessProbe`.

---

## Task 2 — Surface the trigger inputs up through the canvas

**Files:**
- Modify: `Sources/ZenTerm/PaneCanvasController.swift`
- Modify: `Sources/ZenTerm/TabController.swift`

**Consumes:** `TerminalSurface.isBusy` (Task 1); existing `PaneTree.leafIDs`
(public) and `PaneSurfaceRegistry.surface(for:)` (public).
**Produces:** `TabController.isSinglePane: Bool`,
`TabController.focusedPaneIsBusy: Bool`.

**`PaneCanvasController`** (near the existing `focusedCWD`, ~line 77):

```swift
/// Number of leaves (panes) in the tab's canvas. `1` means ⌘W closes the tab.
var paneCount: Int { tree.leafIDs.count }

/// Whether the focused pane's shell has live work (busy). False when the
/// surface hasn't started or the backend can't tell.
var focusedPaneIsBusy: Bool {
    registry.surface(for: tree.focusedLeaf)?.isBusy ?? false
}
```

**`TabController`** (near `focusedCWD`, ~line 124):

```swift
/// True when the tab has a single pane, so ⌘W on it would close the whole tab.
var isSinglePane: Bool { paneCanvas.paneCount == 1 }

/// Whether the focused main-canvas pane has a running process.
var focusedPaneIsBusy: Bool { paneCanvas.focusedPaneIsBusy }
```

**Steps:** ① add the four computed properties; ② `bin/check` (build proves the
plumbing); ③ commit `feat(canvas): expose pane count + focused-pane busy state`.

---

## Task 3 — Toast actions: `ToastAction`, `ToastButton`, sticky confirm

**Files:**
- Create: `Sources/ZenTerm/ToastAction.swift`
- Create: `Sources/ZenTerm/ToastButton.swift`
- Modify: `Sources/ZenTerm/ToastView.swift`
- Modify: `Sources/ZenTerm/ToastPresenter.swift`

**Produces:** `ToastAction`, `ToastButton`,
`ToastView.init(content:tint:actions:)`,
`ToastPresenter.confirm(_:tint:actions:) -> ToastView`,
`ToastPresenter.dismiss(_ toast: ToastView)` (now public).

**`ToastAction.swift`:**

```swift
import AppKit

/// One button on an actionable (confirm) toast.
struct ToastAction {
    enum Kind { case primary, cancel, destructive }
    let title: String
    let kind: Kind
    let run: () -> Void
}
```

**`ToastButton.swift`** — a real `NSButton` so Enter/Esc work as native key
equivalents; styled to the card, not the system bezel:

```swift
import AppKit

/// A small themed button on a confirm toast. Borderless + layer-drawn so it
/// matches the card chrome; carries its `ToastAction.run` and — for primary /
/// cancel — the Return / Esc key equivalents that answer the confirm.
final class ToastButton: NSButton {
    private let run: () -> Void

    // Rosé Pine Moon: love (destructive), gold (primary), muted subtle (cancel).
    private static let love = NSColor(srgbRed: 0xeb / 255, green: 0x6f / 255, blue: 0x92 / 255, alpha: 1)
    private static let gold = NSColor(srgbRed: 0xf6 / 255, green: 0xc1 / 255, blue: 0x77 / 255, alpha: 1)
    private static let subtle = NSColor(srgbRed: 0x90 / 255, green: 0x8c / 255, blue: 0xaa / 255, alpha: 1)
    private static let base = NSColor(srgbRed: 0x19 / 255, green: 0x17 / 255, blue: 0x24 / 255, alpha: 1)

    init(_ action: ToastAction) {
        self.run = action.run
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        bezelStyle = .rounded
        layer?.cornerRadius = 7
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(fire)

        let (fill, border, text): (NSColor?, NSColor, NSColor)
        switch action.kind {
        case .destructive: (fill, border, text) = (Self.love, .clear, .white)
        case .primary: (fill, border, text) = (Self.gold, .clear, Self.base)
        case .cancel: (fill, border, text) = (nil, FloatShadow.edge, Self.subtle)
        }
        layer?.backgroundColor = (fill ?? .clear).cgColor
        layer?.borderWidth = fill == nil ? 1 : 0
        layer?.borderColor = border.cgColor
        attributedTitle = NSAttributedString(
            string: action.title,
            attributes: [
                .foregroundColor: text,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            ])

        switch action.kind {
        case .destructive, .primary: keyEquivalent = "\r"       // Return answers
        case .cancel: keyEquivalent = "\u{1b}"                   // Esc cancels
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}
```

**`ToastView.swift`** — add an actions-bearing init; when actions are present,
render a trailing button row under the message and make the card focusable (so
presenting it moves first responder off the terminal, gating typing). Keep the
existing passive init delegating with `actions: []`.

```swift
// New designated path (existing init delegates here with actions: []):
init(content: ToastContent, tint: NSColor, actions: [ToastAction]) {
    // …existing card/icon/title/message build (unchanged)…
    // after the `col` vertical stack is built and constrained:
    if !actions.isEmpty {
        let row = NSStackView(views: actions.map(ToastButton.init))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        col.addArrangedSubview(row)
        col.setCustomSpacing(11, after: message)   // a touch more air above buttons
    }
}

/// A confirm toast takes keyboard focus so terminal input is gated while it's up.
override var acceptsFirstResponder: Bool { hasActions }
```

Track `hasActions` (`private let hasActions: Bool`, set from `!actions.isEmpty`).
Refactor the current `init(content:tint:)` to call the new init with
`actions: []`; move the shared body into the new designated init.

**`ToastPresenter.swift`** — add a sticky confirm presentation and make
`dismiss` public. The confirm has **no auto-dismiss timer** (a confirmation must
be answered):

```swift
/// Present a sticky, actionable confirm toast (no auto-dismiss). Returns the
/// view so the caller can gate focus and dismiss it on answer.
@discardableResult
func confirm(_ content: ToastContent, tint: NSColor, actions: [ToastAction]) -> ToastView {
    let toast = ToastView(content: content, tint: tint, actions: actions)
    stack.addArrangedSubview(toast)
    toast.animateIn()
    return toast
}

/// Dismiss a toast now (spring out + remove). Idempotent.
func dismiss(_ toast: ToastView) {
    toast.animateOut { [weak self, weak toast] in
        guard let self, let toast else { return }
        self.stack.removeArrangedSubview(toast)
        toast.removeFromSuperview()
    }
}
```

(The existing private `dismiss(_:)` becomes this public one; the passive `show`
path keeps calling it from its timer/click closures.)

**Steps:** ① add `ToastAction.swift`, `ToastButton.swift`; ② extend
`ToastView`/`ToastPresenter`; ③ `bin/check` (build + format + lint; existing
toast still shows in-app); ④ commit `feat(toast): actions row + sticky confirm
presentation`.

---

## Task 4 — ⌘W per-tab confirm (WindowController)

**Files:**
- Modify: `Sources/ZenTerm/WindowController.swift`

**Consumes:** `TabController.isSinglePane` / `.focusedPaneIsBusy` (Task 2);
`ToastPresenter.confirm` / `.dismiss` (Task 3); `ToastPresenter.warning`.
**Produces:** `WindowController.isConfirmOpen: Bool`;
`presentConfirm(icon:title:message:tint:confirmLabel:onConfirm:)`.

**Confirm state + presenter wiring** (near the `toasts` lazy var / the palette
open flags):

```swift
private var confirmToast: ToastView?
var isConfirmOpen: Bool { confirmToast != nil }

/// Present a blocking confirm: focus leaves the terminal (typing is gated) and
/// the modal chord-gate swallows other chords until Cancel / confirm answers.
func presentConfirm(
    icon: String, title: String, message: String, tint: NSColor,
    confirmLabel: String, onConfirm: @escaping () -> Void
) {
    guard confirmToast == nil else { return }   // one confirm at a time
    let content = ToastContent(symbol: icon, title: title, message: message)
    let actions = [
        ToastAction(title: "Cancel", kind: .cancel) { [weak self] in self?.dismissConfirm() },
        ToastAction(title: confirmLabel, kind: .destructive) { [weak self] in
            self?.dismissConfirm()
            onConfirm()
        },
    ]
    let toast = toasts.confirm(content, tint: tint, actions: actions)
    confirmToast = toast
    window.makeFirstResponder(toast)   // gate terminal typing; key equivs still fire
    renderDock()
}

private func dismissConfirm() {
    guard let toast = confirmToast else { return }
    confirmToast = nil
    toasts.dismiss(toast)
    activeController?.restoreKeyFocus()   // hand focus back to the pane
    renderDock()
}
```

**Modal gate** — add near the top of the modal checks in `handle(_:)` (before the
repo-picker / command-palette / lazygit gates, ~line 457): while a confirm is up,
swallow every chord. The buttons + Return/Esc key equivalents answer it:

```swift
if isConfirmOpen { return }
```

**⌘W trigger** — replace the `.closePane` dispatch (currently at ~line 500-502):

```swift
case .closePane:
    requestClosePane()
```

with the trigger logic:

```swift
/// ⌘W: close immediately for an idle non-last pane; otherwise confirm first.
/// Confirm when the focused pane has running work, or it's the tab's last pane
/// (closing it destroys the tab). `exit`/middle-click stay out of scope.
private func requestClosePane() {
    guard let active = activeController else { return }
    let lastPane = active.isSinglePane
    guard lastPane || active.focusedPaneIsBusy else {
        _ = active.closeFocused()   // idle, panes remain → close now
        return
    }
    let title = lastPane ? "Close tab?" : "Close pane?"
    let message = lastPane ? "This closes the tab." : "A process is still running here."
    presentConfirm(
        icon: "xmark.circle.fill", title: title, message: message,
        tint: ToastPresenter.warning, confirmLabel: "Close"
    ) { [weak self] in
        guard let self, let active = self.activeController else { return }
        if active.closeFocused() == false { self.closeTab(self.tabs.activeID) }
    }
}
```

**Note (documented, acceptable for v1):** with no backdrop, clicking a pane while
the confirm is up refocuses that pane; the confirm stays visible and Return/Esc
(or the buttons) still answer it, since `NSButton` key equivalents fire
window-wide via `performKeyEquivalent`.

**Verify (manual runbook):**
1. ⌘W on an idle non-last pane (split first, run nothing) → closes instantly, no
   confirm.
2. ⌘W on a pane running `sleep 60` / `vim` → *"Close pane?"*; Cancel keeps it;
   Return/Close kills it.
3. ⌘W on a single-pane tab → *"Close tab?"*; Esc cancels; Close destroys the tab.
4. While the confirm is up, split/nav/drawer/zoom chords do nothing; Return =
   Close, Esc = Cancel; focus returns to the pane after either.

**Steps:** ① add the confirm state + `presentConfirm`/`dismissConfirm`; ② add the
`isConfirmOpen` gate; ③ swap `.closePane` for `requestClosePane()`; ④ `bin/check`;
⑤ run the runbook via `swift run ZenTerm`; ⑥ commit `feat(close): confirm ⌘W on
busy or last pane`.

---

## Task 5 — ⌘Q app-quit confirm (AppDelegate + WindowController)

**Files:**
- Modify: `Sources/ZenTerm/AppDelegate.swift`
- Modify: `Sources/ZenTerm/WindowController.swift`

**Consumes:** `presentConfirm` / `isConfirmOpen` (Task 4); `AppDelegate.windows`,
`AppDelegate.keyController()`.
**Produces:** `WindowController.tabCount: Int`;
`WindowController.presentQuitConfirm(tabCount:windowCount:onQuit:)`.

**`WindowController`:**

```swift
/// Number of open tabs in this window (for the quit tally).
var tabCount: Int { tabs.order.count }

/// Present the app-quit confirm on this (key) window.
func presentQuitConfirm(tabCount: Int, windowCount: Int, onQuit: @escaping () -> Void) {
    let tabs = "\(tabCount) tab\(tabCount == 1 ? "" : "s")"
    let message = windowCount == 1
        ? "\(tabs) will close."
        : "\(tabs) in \(windowCount) windows will close."
    presentConfirm(
        icon: "power", title: "Quit ZenTerm?", message: message,
        tint: ToastPresenter.warning, confirmLabel: "Quit", onConfirm: onQuit)
}
```

**`AppDelegate`** — gate termination (always confirm, per the approved
decision):

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let key = keyController() else { return .terminateNow }
    if key.isConfirmOpen { return .terminateCancel }   // a confirm is already pending
    let tabCount = windows.reduce(0) { $0 + $1.tabCount }
    key.presentQuitConfirm(tabCount: tabCount, windowCount: windows.count) {
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    // Cancel path: the confirm dismisses and we never reply true → app keeps running.
    return .terminateLater
}
```

`keyController()` is currently `private` — leave it private; `applicationShould
Terminate` lives in the same type. `.terminateLater` requires a matching
`reply(toApplicationShouldTerminate:)`; the Quit button supplies `true`. Cancel
simply dismisses (never replies true), and because we returned `.terminateLater`
the app stays alive — the pending request is abandoned when the next ⌘Q starts a
fresh confirm.

**Verify (manual runbook):**
5. ⌘Q with 2 tabs in one window → *"Quit ZenTerm? 2 tabs will close."*; Cancel
   aborts quit (app stays); Quit exits.
6. ⌘Q with 1 tab → *"1 tab will close."* (singular, no window clause).
7. Two windows open (⌘N), tabs in each → count sums both, window clause shown.
8. Reduce Motion on → confirm still appears + gates; no spring.

**Steps:** ① add `tabCount` + `presentQuitConfirm`; ② add
`applicationShouldTerminate`; ③ `bin/check`; ④ run the runbook; ⑤ commit
`feat(quit): confirm ⌘Q with open-tab tally`.

---

## Final verification & ship

- `bin/check` fully green (build, `swift test` incl. `ProcessProbeTests`, format
  lint, swiftlint).
- Walk the full runbook (Tasks 4 + 5, steps 1-8) via `swift run ZenTerm`.
- `/code-review` on the branch diff; triage every finding (fix / mitigate /
  ignore) with no tech debt; re-run `bin/check`.
- Move Linear **ZEN-49 → In Review** (`c8f755f6-5c17-4bdd-b41f-9161166fdb19`).
  Branch `feature/zen-49-close-this-tab-warning-when-exiting-the-last-main-pane`
  is already off main (includes merged ZEN-48); push + open PR referencing
  ZEN-49.

## Files at a glance

| File | Change |
| --- | --- |
| `Sources/TerminalKit/ProcessProbe.swift` | **new** — `hasChildren(pid)` |
| `Sources/TerminalKit/TerminalSurface.swift` | `isBusy` protocol member + default |
| `Sources/TerminalKit/SwiftTermSurface.swift` | implement `isBusy` |
| `Sources/ZenTerm/PaneCanvasController.swift` | `paneCount`, `focusedPaneIsBusy` |
| `Sources/ZenTerm/TabController.swift` | `isSinglePane`, `focusedPaneIsBusy` |
| `Sources/ZenTerm/ToastAction.swift` | **new** — `ToastAction` |
| `Sources/ZenTerm/ToastButton.swift` | **new** — themed `NSButton` |
| `Sources/ZenTerm/ToastView.swift` | actions row + focusable/sticky |
| `Sources/ZenTerm/ToastPresenter.swift` | `confirm(...)`, public `dismiss` |
| `Sources/ZenTerm/WindowController.swift` | confirm state, gate, `requestClosePane`, quit confirm |
| `Sources/ZenTerm/AppDelegate.swift` | `applicationShouldTerminate` |
| `Tests/TerminalKitTests/ProcessProbeTests.swift` | **new** — busy probe tests |
