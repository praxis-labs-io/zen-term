# Epic 0 Delegate Spike — bell / OSC 9 notify / OSC 9;4 progress

**Question:** Can zen-term surface SwiftTerm's below-view-delegate signals — bell,
OSC 9 desktop notifications, and OSC 9;4 progress — by **subclassing**
`LocalProcessTerminalView`? These underpin Epic 4's toast/statusline story
(agent idle/working, task progress), so we de-risk them now with evidence rather
than assumption.

**Method:** A `ProbeTerminalView: LocalProcessTerminalView` subclass attempting to
override each callback, checked against the resolved SwiftTerm 1.13.0 source
(`.build/checkouts/SwiftTerm/Sources/SwiftTerm/`) and a real build. Runtime
confirmation via `swift run ZenTerm` and emitting the escape sequences by hand.

## Findings

| Signal | Reachable by subclass? | Mechanism / why |
|---|---|---|
| **bell** | ✅ **Yes** | `TerminalView.bell(source:)` is `open` → a subclass override compiles and participates in vtable dispatch. **Runtime-confirmed:** typing `printf '\a'` fires `onBell` and logs `[bell]`. |
| **notify** (OSC 9) | ❌ No | `TerminalView` never implements `notify(source:title:body:)` — only the `TerminalDelegate` extension's no-op default applies. There is no superclass member to override; the compiler rejects the attempt with *"method does not override any method from its superclass."* |
| **progress** (OSC 9;4) | ❌ No | `TerminalView.progressReport(source:report:)` is `public`, not `open`. A subclass in another module cannot override it; the compiler rejects with *"overriding non-open instance method outside of its defining module."* |

Notes:
- The audible/visible bell is SwiftTerm's own concern — `super.bell(source:)` does
  not necessarily sound the system bell. Reachability of the **event** (what the
  spike measures) is what's confirmed: our delegate fires.
- SwiftTerm's `ProgressReportState` enum cases are `.remove`, `.set`, `.error`,
  `.indeterminate`, `.pause` (the plan's draft used `.paused`/`.none`, which do not
  exist). Moot for now since `progressReport` isn't overridable, but recorded so a
  future mapping uses the real names.

## Implication for Epic 4

Bell is available today. **notify and progress are NOT reachable by subclassing
SwiftTerm as shipped.** Before Epic 4 commits to a progress/notify toast, resolve
this by one of, in order of preference:

1. **Delegate-property hook** — investigate whether these can be received by
   *setting* a delegate SwiftTerm exposes (rather than subclassing). Not yet
   explored; cheapest if it exists.
2. **Upstream** — PR SwiftTerm to mark `progressReport` `open` and add a real
   `notify` hook. Clean but depends on maintainer.
3. **Fork** — vendor SwiftTerm with those members opened. Full control, more
   maintenance.

This is an **Epic 4 entry risk**, surfaced cheaply here. It does not block Epic 0.
