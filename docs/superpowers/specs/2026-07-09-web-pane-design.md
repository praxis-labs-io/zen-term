# Web Panes — Pinned Webview Viewer

**Status:** approved 2026-07-09.

## Goal

A **web pane**: a tile-first `WKWebView` that lives in the pane tree next to
terminals, or as the main pane. It is a **pinned viewer** — bound to a URL you
pick, not a browser. No URL bar, no back/forward. The core job is *"watch my dev
app / a dashboard / Linear right alongside the terminal running it,"* with a
**device-viewport switch** (desktop / tablet / phone) that reflows the page at
real device widths so responsive breakpoints genuinely trigger.

A web pane satisfies the existing `TerminalSurface` seam — it is a second
implementation of "anything that can be a pane in our chrome." Splits, focus
halo, zoom, resize, cross-pane nav, and the drawer/float machinery all work
unchanged, because they only touch `surface.view` and the protocol.

> Naming note: the seam protocol is called `TerminalSurface`, but it is
> conceptually `PaneSurface` ("anything that can be a pane"). We conform
> `WebPaneSurface` to it as-is rather than take a churny rename. If the protocol
> is ever renamed, that is a separate mechanical change.

## Behavior

### Trigger & picker

- **`⌘⇧B`** ("browser") opens a centered modal palette over the active tab —
  same overlay family as the `⌘P` repo picker and the lazygit float
  (tile-scoped, rounded, dim backdrop, centered card). `⌘⇧B` again closes it.
  Noted as **tunable**.
- **Mutually exclusive with other modals** (lazygit float, repo picker): while
  any is open the others are blocked by the existing modal gate in
  `WindowController.handle`; while the web picker is open it is itself modal (all
  chrome chords swallowed except `⌘⇧B`, which closes it).
- The picker mirrors the repo picker: a result list + a hint footer
  (`↵ split   ⇧↵ replace   ↑↓ move   esc close`). A search field is present for
  parity but the v1 list is only five rows.

### Presets (v1 hardcoded)

Five URLs, configurable later:

1. `http://localhost:3000`
2. `http://localhost:3001`
3. `http://localhost:3002`
4. `http://team.localhost:3000`
5. `http://admin.localhost:3000`

### Placement

- **Enter** → **split** the focused leaf (respecting the current split
  direction), the web pane takes the new half. Same as splitting a terminal.
- **Shift+Enter** → **replace** the focused leaf in place: its surface is
  swapped terminal→web without changing the tree shape (see Respawn below). A
  busy terminal follows the existing close-confirm path before being torn down.
- **Esc** → close the picker, no action.

### Pane chrome (per web leaf)

Populated in `PanelHostView`'s existing optional meta header — backend-agnostic;
the controller shows a web header for web leaves and wires the buttons to the
resolved `WebPaneSurface`:

- **URL/host label** — so you can tell which app is which (e.g. `localhost:3000`).
- **Reload button** — plus **`⌘R`**, intercepted **only when the focused leaf is
  web** (kind-gated in the reserved-chord handler) so terminals never lose the
  key.
- **Device segmented control** — desktop / tablet / phone.

### Device viewport

- **`.desktop`** — full pane width, no letterbox.
- **`.tablet`** — 768pt. **`.phone`** — 390pt. Widths are constants now,
  configurable later.
- Non-desktop presets constrain the **actual `WKWebView` frame width** to the
  device width and center it, filling the remainder of the pane with the pane
  background (letterbox). No zoom — WebKit lays out at that literal width, so
  responsive CSS reflows exactly as it would on the device. The web view fills
  the full pane height and scrolls internally.

### Dev-server-not-up state

No auto-retry (explicitly out of scope). Instead of WebKit's default error page,
a failed load shows a clean *"Can't reach localhost:3000"* state; the reload
button already in the header recovers it once the dev server is warm.

### Focus, title, busy

- `WKWebView` owns the keyboard while focused; a click reports
  `delegate?.surfaceWantsFocus(self)` so unified focus keeps working. `⌘hjkl`
  cross-pane nav, zoom, and resize are unchanged (frames + `surface.view` only).
- **`title`** ← page title, falling back to the URL host; feeds the existing
  tab-title plumbing.
- **`isBusy`** ← `webView.isLoading`, so the existing pane busy/spinner
  indicator lights up during loads for free.

## Architecture

### New target: `WebPaneKit`

Depends on `TerminalKit` **only** (for the `TerminalSurface` protocol type,
exactly as `PaneKit` does) and links `WebKit`. `ZenTerm` gains a dependency on
it. This preserves the rule that only `TerminalKit` touches terminal backends,
and mirrors the existing layering.

- **`DevicePreset`** (`Sources/WebPaneKit/DevicePreset.swift`) — enum
  `.desktop | .tablet | .phone`; `var width: CGFloat?` (nil = full).
- **`WebPaneSurface`** (`Sources/WebPaneKit/WebPaneSurface.swift`) —
  `final class WebPaneSurface: TerminalSurface`. Constructed with
  `(url: URL, device: DevicePreset)`. Owns a `WKWebView` inside a
  `WebPaneHostView`.
  - Seam mapping: `view` → host view; `title` → page title ?? host;
    `currentDirectory` → nil; `isBusy` → `webView.isLoading`; `focus()` → make
    the web view first responder; `start(_:)` → no-op (URL injected at
    construction, load kicked off there); `terminate()` → stop loading + tear
    down; `paste`/`copySelection`/`scrollToBottom` → no-op in v1.
  - Web-only API (not on the protocol): `func reload()`,
    `func setDevice(_:)`, `var currentURL: URL`. Reached by the controller
    resolving the surface as `WebPaneSurface`.
  - Emits `surfaceWantsFocus`, `titleDidChange`, and (via KVO on `isLoading`)
    keeps `isBusy` fresh through the delegate.
- **`WebPaneHostView`** (`Sources/WebPaneKit/WebPaneHostView.swift`) — hosts the
  `WKWebView`, applies the device-width constraint (centered + letterboxed for
  non-desktop), paints the letterbox background. Device-width geometry is pure
  and unit-testable.

### PaneKit (one mechanical change)

- `PaneSurfaceRegistry.makeSurface` changes from `() -> TerminalSurface` to
  **`(PaneID) -> TerminalSurface`**; `apply(_:)` passes each created leaf's id.
  Retained/removed lifecycle is unchanged. The `PaneNode`/`PaneTree`/`PaneDiff`/
  `PaneTreeOps` value types are **untouched** — a leaf is still just a `PaneID`.

### ZenTerm (chrome)

- **`PaneSpec`** — `enum PaneSpec { case terminal(cwd: URL?); case web(url: URL,
  device: DevicePreset) }`, held in a side-map `[PaneID: PaneSpec]` on
  `PaneCanvasController`. This is where a leaf's *kind* lives — the pure tree
  stays kind-agnostic.
- **`PaneCanvasController`**:
  - The `makeSurface(id)` closure switches on `paneSpecs[id]`:
    `.terminal` → `TerminalSurfaceFactory.make()`; `.web` →
    `WebPaneSurface(url:device:)`. Defaults to `.terminal` for any leaf without
    a recorded spec (all existing paths).
  - **Split-as-web**: on picker Enter, split the focused leaf via the existing
    tree op, then record `.web` for the new leaf id before reconcile.
  - **Respawn on spec change**: the diff treats a replaced leaf as *retained*
    (same `PaneID`), so it will not recreate the surface. The controller does a
    targeted terminate + recreate for a leaf whose spec changed — the path for
    Shift+Enter replace (and future re-point).
  - Shows the web meta header for `.web` leaves and wires reload / device
    controls to the resolved `WebPaneSurface`; routes `⌘R` to it when the
    focused leaf is web.
- **`WebPanePickerOverlay`** (`Sources/ZenTerm/WebPanePickerOverlay.swift`) — the
  palette (list + footer + parity search field), owns selection + keyboard,
  emits `onChoose(URL, replaceFocused: Bool)` and `onDismiss()`. Reuses the
  overlay chrome idiom from `RepoPickerOverlay`/`LazygitOverlay`.
- **`WindowController`** — owns the picker lifecycle (`toggleWebPanePicker()`,
  `isWebPanePickerOpen`); extends the modal gate to swallow chords except `⌘⇧B`
  while open. On choose, forwards split/replace to the active tab's
  `PaneCanvasController`.
- **`KeyInterceptor`** — add `case toggleWebPanePicker` to `ReservedChord`
  (`⌘⇧B`) and `case reloadWebPane` (`⌘R`, kind-gated at the handler).

## Testing

- **Unit (`WebPaneHostView` geometry):** given pane width W and a device width D,
  the web-view frame is D wide and horizontally centered (letterbox = (W − D)/2
  each side); desktop → full width, no inset. No page load needed.
- **Unit (`DevicePreset`):** width mapping (`nil`/768/390).
- **Unit (`PaneSurfaceRegistry`):** `apply` passes the correct `PaneID` to
  `makeSurface`; a fake factory asserts the id and returns a fake surface. A
  leaf whose spec changed is terminated and recreated (respawn), retained
  leaves with unchanged specs are left alone.
- **Manual runbook:**
  1. `⌘⇧B` → palette opens centered over the tab; five presets listed; footer
     hints show; `↑/↓` moves the iris selection.
  2. `Enter` on `localhost:3000` → focused pane splits; web pane renders the app;
     header shows the host label, reload, and the device control.
  3. Switch to **phone** → the page reflows at 390pt, centered and letterboxed;
     **tablet** → 768pt; **desktop** → full width.
  4. Reload button and `⌘R` (web pane focused) reload; `⌘R` in a terminal pane is
     passed through to the shell.
  5. With the dev server down, the pane shows the clean unreachable state; start
     the server, hit reload → it loads.
  6. `Shift+Enter` on a preset → the focused terminal leaf is replaced in place by
     the web pane (tree shape unchanged); a busy shell hits the close-confirm
     first.
  7. `⌘hjkl` nav, `⌘` zoom, and resize behave identically across terminal and web
     panes.

## Out of scope (v1)

Real browser navigation (URL bar, back/forward, link history), user-agent /
device-pixel-ratio spoofing, auto-retry on unreachable URLs, re-pointing a web
pane's URL in place, config-file-defined presets (the five are hardcoded),
cross-relaunch persistence (web panes are ephemeral, consistent with session
persistence being off-roadmap), copy/paste/scroll bridging into the page, and
DevTools/inspector.
