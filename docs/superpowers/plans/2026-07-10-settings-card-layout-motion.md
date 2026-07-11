# Settings card — Layout & Motion section Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Layout & Motion section to the Settings card — sliders/fields/segmented editors for the chrome layout knobs, motion preference, and shell fields — that write back to `config` and apply live wherever the value isn't owned by runtime state.

**Architecture:** A new `SettingsSection` (`SettingsLayoutSection`) rendered in the existing `SettingsOverlay`, reusing PR1's `ConfigWriter.apply(scalars:removals:)` for writes/resets and `AppConfig.reload()` for the live seam. Numeric knobs use a new shared `Slider` primitive (0–1 values) or `FieldBox` (pixels); `reduce-motion` uses `SegmentedControl`; shell fields use `FieldBox`. Live re-apply is wired through three contained `configDidChange` hooks.

**Tech Stack:** Swift + AppKit, SwiftPM, XCTest. Module `Sources/ZenTerm` (chrome; never imports SwiftTerm).

## Global Constraints

- **Config keys + parser clamps are the source of truth for validation ranges** (from `GeneralConfigParser`): `backdrop-alpha` 0–1, `window-gutter` 0–64, `pane-gap` 0–64, `bottom-drawer-fraction` 0.1–0.9, `right-drawer-fraction` 0.1–0.9, `drawer-resize-step` 4–400, `max-drawer-fraction` 0.3–0.95, `reduce-motion` ∈ {system,on,off}, `shell` non-empty string, `shell-args` whitespace-split. UI slider/field ranges must sit within these; validation rejects out-of-range before writing.
- **Live-apply tiers** (do not force the new-tab ones live): live = `backdrop-alpha`, `window-gutter`, `pane-gap`, `drawer-resize-step`, `max-drawer-fraction`, `reduce-motion`; new-tab-only = `bottom-drawer-fraction`, `right-drawer-fraction`, `shell`, `shell-args`.
- **Chrome never hardcodes a color.** All colors from `Theme.current.chrome` roles / `chrome.ink(alpha:)`. Banned: `.white`/`.black`, `NSColor(white:)`, raw hex.
- **No force-unwrap** except documented AppKit (`contentView!`). No `TODO`/`FIXME`. `import type`-equivalent N/A (Swift). Prefer `struct`/`final class`.
- **Reuse the ZEN-81 shared controls.** The only new primitive is `Slider`. `FieldBox` and `SegmentedControl` gain **additive, default-nil** `onTab`/`onBacktab` hooks (no behavior change for the Add-Workspace form, which never sets them) — the same additive pattern PR1 used for `AppButton.onEsc`. This is required by the approved Tab-to-reset keyboard model.
- **Keyboard model (approved):** ↑/↓ move rows (+ Reset-all); ←/→ operate the focused control (slider nudge / segment pick / text cursor); **Tab reaches the per-row reset icon, ← (or ⇧Tab) returns to the control**; Esc closes from any control.
- **`ConfigWriter` is consumed as-is** (no changes to it). Per-row reset = a `removals` write (drops the key → parser returns `builtIn`).
- `bin/check` fully green: build + `swift test` + `swift format lint --strict` + `swiftlint --strict`.

---

### Task 1: `Slider` shared primitive

**Files:**
- Create: `Sources/ZenTerm/Controls/Slider.swift`
- Test: `Tests/ZenTermTests/SliderTests.swift`

**Interfaces:**
- Produces: `Slider` — `init(value: CGFloat, range: ClosedRange<CGFloat>, step: CGFloat, onChange: @escaping (CGFloat) -> Void)`; `var value: CGFloat { get }`; `func setValue(_:)`; keyboard hooks `onArrowUp`/`onArrowDown`/`onTab`/`onBacktab`/`onEsc`; static pure math `Slider.snap(_:range:step:)` and `Slider.nudged(_:steps:range:step:)`.
- Consumes: `Theme.current.chrome`, `Motion` (none needed).

- [ ] **Step 1: Write the failing math tests**

```swift
// Tests/ZenTermTests/SliderTests.swift
import XCTest
@testable import ZenTerm

final class SliderTests: XCTestCase {
    func test_snap_clampsToRange() {
        XCTAssertEqual(Slider.snap(1.5, range: 0...1, step: 0.02), 1.0, accuracy: 0.0001)
        XCTAssertEqual(Slider.snap(-0.3, range: 0...1, step: 0.02), 0.0, accuracy: 0.0001)
    }

    func test_snap_quantizesToStepGrid() {
        XCTAssertEqual(Slider.snap(0.837, range: 0...1, step: 0.02), 0.84, accuracy: 0.0001)
        XCTAssertEqual(Slider.snap(0.28, range: 0.1...0.9, step: 0.01), 0.28, accuracy: 0.0001)
    }

    func test_nudged_movesByStepAndClamps() {
        XCTAssertEqual(Slider.nudged(0.82, steps: 1, range: 0...1, step: 0.02), 0.84, accuracy: 0.0001)
        XCTAssertEqual(Slider.nudged(0.82, steps: -1, range: 0...1, step: 0.02), 0.80, accuracy: 0.0001)
        XCTAssertEqual(Slider.nudged(1.0, steps: 1, range: 0...1, step: 0.02), 1.0, accuracy: 0.0001)
        XCTAssertEqual(Slider.nudged(0.0, steps: -1, range: 0...1, step: 0.02), 0.0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SliderTests`
Expected: FAIL — `Slider` not defined.

- [ ] **Step 3: Implement `Slider`**

```swift
// Sources/ZenTerm/Controls/Slider.swift
import AppKit

/// A theme-driven, keyboard-navigable slider for a bounded scalar (backdrop alpha, drawer
/// fractions). A focus stop in the 2D form flow — Left/Right nudge by `step`, Up/Down bubble to
/// move between rows, Tab reaches the row's reset icon. Draws a track, an accent fill, and a thumb,
/// plus a trailing value label. A shared form-control primitive (joins the ZEN-81 set).
final class Slider: NSView {
    private(set) var value: CGFloat
    var onChange: (CGFloat) -> Void
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onEsc: (() -> Void)?

    private let range: ClosedRange<CGFloat>
    private let step: CGFloat
    private let track = NSView()
    private let fill = NSView()
    private let thumb = NSView()
    private let valueLabel = NSTextField(labelWithString: "")
    private var isFocused = false { didSet { restyle() } }

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 14

    /// Pure: clamp to `range`, then quantize to the nearest `step` offset from `range.lowerBound`.
    static func snap(_ value: CGFloat, range: ClosedRange<CGFloat>, step: CGFloat) -> CGFloat {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let steps = ((clamped - range.lowerBound) / step).rounded()
        let snapped = range.lowerBound + steps * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// Pure: move `value` by `steps` grid steps, clamped/quantized.
    static func nudged(_ value: CGFloat, steps: Int, range: ClosedRange<CGFloat>, step: CGFloat) -> CGFloat {
        snap(value + CGFloat(steps) * step, range: range, step: step)
    }

    init(value: CGFloat, range: ClosedRange<CGFloat>, step: CGFloat, onChange: @escaping (CGFloat) -> Void) {
        self.range = range
        self.step = step
        self.onChange = onChange
        self.value = Slider.snap(value, range: range, step: step)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        for view in [track, fill, thumb] {
            view.wantsLayer = true
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        track.layer?.cornerRadius = trackHeight / 2
        fill.layer?.cornerRadius = trackHeight / 2
        thumb.layer?.cornerRadius = thumbSize / 2

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 40),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -10),
            track.centerYAnchor.constraint(equalTo: centerYAnchor),
            track.heightAnchor.constraint(equalToConstant: trackHeight),
            thumb.widthAnchor.constraint(equalToConstant: thumbSize),
            thumb.heightAnchor.constraint(equalToConstant: thumbSize),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setValue(_ newValue: CGFloat) {
        value = Slider.snap(newValue, range: range, step: step)
        restyle()
    }

    override func layout() {
        super.layout()
        // Position the fill + thumb along the track for the current value.
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let usable = track.frame.width - thumbSize
        let x = track.frame.minX + thumbSize / 2 + max(0, min(1, fraction)) * usable
        fill.frame = NSRect(x: track.frame.minX, y: track.frame.minY, width: x - track.frame.minX, height: trackHeight)
        thumb.frame = NSRect(x: x - thumbSize / 2, y: (bounds.height - thumbSize) / 2, width: thumbSize, height: thumbSize)
    }

    // MARK: keyboard

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: apply(Slider.nudged(value, steps: -1, range: range, step: step))  // left
        case 124: apply(Slider.nudged(value, steps: 1, range: range, step: step))  // right
        case 126: onArrowUp?()  // up
        case 125: onArrowDown?()  // down
        case 48: event.modifierFlags.contains(.shift) ? onBacktab?() : onTab?()  // ⇧tab / tab
        case 53 where onEsc != nil: onEsc?()  // esc
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) { drag(event) }
    override func mouseDragged(with event: NSEvent) { drag(event) }

    private func drag(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        let usable = track.frame.width - thumbSize
        guard usable > 0 else { return }
        let fraction = (local.x - track.frame.minX - thumbSize / 2) / usable
        apply(Slider.snap(range.lowerBound + fraction * (range.upperBound - range.lowerBound), range: range, step: step))
    }

    private func apply(_ newValue: CGFloat) {
        guard newValue != value else { return }
        value = newValue
        restyle()
        onChange(value)
    }

    private func restyle() {
        let chrome = Theme.current.chrome
        track.layer?.backgroundColor = chrome.ink(alpha: 0.12).cgColor
        fill.layer?.backgroundColor = chrome.accent.nsColor.cgColor
        thumb.layer?.backgroundColor = chrome.accent.nsColor.cgColor
        thumb.layer?.borderWidth = isFocused ? 3 : 0
        thumb.layer?.borderColor = isFocused ? chrome.accent.nsColor.withAlphaComponent(0.35).cgColor : nil
        valueLabel.stringValue = LayoutFormat.number(value)
        valueLabel.textColor = chrome.muted.nsColor
        needsLayout = true
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SliderTests`
Expected: PASS (3 tests). NOTE: `restyle()` references `LayoutFormat.number` from Task 2 — if Task 1 is built before Task 2, temporarily inline `String(format: "%g", Double(value))` here and replace with `LayoutFormat.number` in Task 2. (Recommended: build Task 2 first, then Task 1; see task order note.)

- [ ] **Step 5: `swift build` + commit**

Run: `swift build` (clean), then commit.

```bash
git add Sources/ZenTerm/Controls/Slider.swift Tests/ZenTermTests/SliderTests.swift
git commit -m "Add shared Slider primitive (keyboard-navigable, theme-driven)"
```

---

### Task 2: Layout value formatting + parsing helpers

**Files:**
- Create: `Sources/ZenTerm/LayoutFormat.swift`
- Test: `Tests/ZenTermTests/LayoutFormatTests.swift`

**Interfaces:**
- Produces: `enum LayoutFormat` — `static func number(_ value: CGFloat) -> String`; `static func parseNumber(_ text: String, in range: ClosedRange<CGFloat>) -> CGFloat?`; `static func reduceMotionToken(_:) -> String`; `static func reduceMotion(fromIndex:) -> GeneralConfig.ReduceMotion`; `static func reduceMotionIndex(_:) -> Int`; `static func joinArgs(_:) -> String`; `static func splitArgs(_:) -> [String]`.
- Consumes: `GeneralConfig.ReduceMotion`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/ZenTermTests/LayoutFormatTests.swift
import XCTest
@testable import ZenTerm

final class LayoutFormatTests: XCTestCase {
    func test_number_trimsTrailingZeros() {
        XCTAssertEqual(LayoutFormat.number(0.82), "0.82")
        XCTAssertEqual(LayoutFormat.number(8), "8")
        XCTAssertEqual(LayoutFormat.number(0.3), "0.3")
        XCTAssertEqual(LayoutFormat.number(0.70), "0.7")
    }

    func test_parseNumber_rejectsNonNumericAndOutOfRange() {
        XCTAssertNil(LayoutFormat.parseNumber("abc", in: 0...64))
        XCTAssertNil(LayoutFormat.parseNumber("", in: 0...64))
        XCTAssertNil(LayoutFormat.parseNumber("99", in: 0...64))
        XCTAssertNil(LayoutFormat.parseNumber("-1", in: 0...64))
    }

    func test_parseNumber_acceptsInRange() {
        XCTAssertEqual(LayoutFormat.parseNumber("8", in: 0...64), 8)
        XCTAssertEqual(LayoutFormat.parseNumber(" 0.82 ", in: 0...1), 0.82)
    }

    func test_reduceMotion_indexRoundTrips() {
        for (index, r) in [(0, GeneralConfig.ReduceMotion.system), (1, .on), (2, .off)] {
            XCTAssertEqual(LayoutFormat.reduceMotion(fromIndex: index), r)
            XCTAssertEqual(LayoutFormat.reduceMotionIndex(r), index)
        }
        XCTAssertEqual(LayoutFormat.reduceMotionToken(.on), "on")
    }

    func test_args_joinSplitRoundTrips() {
        XCTAssertEqual(LayoutFormat.joinArgs(["-l", "--login"]), "-l --login")
        XCTAssertEqual(LayoutFormat.splitArgs("  -l   --login "), ["-l", "--login"])
        XCTAssertEqual(LayoutFormat.splitArgs(""), [])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LayoutFormatTests`
Expected: FAIL — `LayoutFormat` not defined.

- [ ] **Step 3: Implement `LayoutFormat`**

```swift
// Sources/ZenTerm/LayoutFormat.swift
import CoreGraphics
import Foundation

/// Value ↔ config-string helpers for the Layout & Motion settings section: render a scalar to the
/// minimal decimal form the `config` file uses, parse+range-validate a typed field, and map the
/// `reduce-motion` enum and `shell-args` list to/from their string forms.
enum LayoutFormat {
    /// Minimal-decimal string (`0.82`, `8`, `0.7`) — `%g` uses the C locale (period) and drops
    /// trailing zeros, matching how the file is hand-written and re-parsed.
    static func number(_ value: CGFloat) -> String { String(format: "%g", Double(value)) }

    /// Parse a numeric field, returning the value only when it's a number inside `range`.
    static func parseNumber(_ text: String, in range: ClosedRange<CGFloat>) -> CGFloat? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let n = Double(trimmed) else { return nil }
        let value = CGFloat(n)
        return range.contains(value) ? value : nil
    }

    static func reduceMotionToken(_ r: GeneralConfig.ReduceMotion) -> String {
        switch r {
        case .system: return "system"
        case .on: return "on"
        case .off: return "off"
        }
    }

    static func reduceMotionIndex(_ r: GeneralConfig.ReduceMotion) -> Int {
        switch r {
        case .system: return 0
        case .on: return 1
        case .off: return 2
        }
    }

    static func reduceMotion(fromIndex index: Int) -> GeneralConfig.ReduceMotion {
        switch index {
        case 1: return .on
        case 2: return .off
        default: return .system
        }
    }

    static func joinArgs(_ args: [String]) -> String { args.joined(separator: " ") }

    static func splitArgs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LayoutFormatTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/LayoutFormat.swift Tests/ZenTermTests/LayoutFormatTests.swift
git commit -m "Add LayoutFormat value <-> config-string helpers for the Layout section"
```

---

### Task 3: `LayoutRow` + `SettingsLayoutSection` (the editor) + nav registration

**Files:**
- Create: `Sources/ZenTerm/LayoutRow.swift`
- Create: `Sources/ZenTerm/SettingsLayoutSection.swift`
- Modify: `Sources/ZenTerm/Controls/FieldBox.swift` (add additive `onTab`/`onBacktab`)
- Modify: `Sources/ZenTerm/Controls/SegmentedControl.swift` (add additive `onTab`/`onBacktab`)
- Modify: `Sources/ZenTerm/WindowController.swift:463` (register the section)
- Test: `Tests/ZenTermTests/LayoutWriteTests.swift`

**Interfaces:**
- Consumes: `Slider` (Task 1), `LayoutFormat` (Task 2), `ConfigWriter.apply(scalars:removals:configRoot:)`, `AppConfig.reload()`, `GeneralConfig.current`/`.builtIn`, `SettingsSection`, `SlimScroller`/`FlippedView`, `AppButton`, `FieldBox`, `SegmentedControl`, `LabeledField`.
- Produces: `SettingsLayoutSection: SettingsSection` (`navTitle == "Layout & Motion"`), `LayoutRow: NSView`.

- [ ] **Step 1: Write the failing write-path test**

The section's write/reset semantics are unit-testable through `ConfigWriter` (the GUI wiring is runbook-verified). Verify a representative scalar write + reset round-trips through the real loader, exactly as the section will call it.

```swift
// Tests/ZenTermTests/LayoutWriteTests.swift
import CoreGraphics
import XCTest
@testable import ZenTerm

final class LayoutWriteTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zt-layout-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_scalarWrite_thenReset_roundTripsThroughLoader() throws {
        let dir = try makeTempDir()
        // Write two edited knobs the way the section does.
        try ConfigWriter.apply(
            scalars: ["backdrop-alpha": LayoutFormat.number(0.5), "reduce-motion": "on"], configRoot: dir)
        var loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(loaded.backdropAlpha, 0.5, accuracy: 0.0001)
        XCTAssertEqual(loaded.reduceMotion, .on)

        // Per-row reset = removal → the key drops out, parser returns builtIn.
        try ConfigWriter.apply(removals: ["backdrop-alpha", "reduce-motion"], configRoot: dir)
        loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(loaded.backdropAlpha, GeneralConfig.builtIn.backdropAlpha, accuracy: 0.0001)
        XCTAssertEqual(loaded.reduceMotion, GeneralConfig.builtIn.reduceMotion)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails/passes-for-the-right-reason**

Run: `swift test --filter LayoutWriteTests`
Expected: PASS immediately (it exercises existing `ConfigWriter`/`ConfigLoader`). This test guards the write/reset contract the section depends on; keep it green while building the section. (If it fails, the section's assumptions are wrong — stop and fix.)

- [ ] **Step 3: Add additive `onTab`/`onBacktab` to `FieldBox`**

In `Sources/ZenTerm/Controls/FieldBox.swift`, add the two optional hooks near the other arrow hooks:

```swift
    /// Tab / Shift-Tab out of the field (opt-in, default nil) — the Layout section routes Tab to
    /// the row's reset icon. Unset elsewhere, so the field keeps default tab behavior.
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
```

And in `control(_:textView:doCommandBy:)`, add cases before `default`:

```swift
        case #selector(NSResponder.insertTab(_:)):
            guard let onTab else { return false }
            onTab()
        case #selector(NSResponder.insertBacktab(_:)):
            guard let onBacktab else { return false }
            onBacktab()
```

- [ ] **Step 4: Add additive `onTab`/`onBacktab` to `SegmentedControl`**

In `Sources/ZenTerm/Controls/SegmentedControl.swift`, add the hooks near `onArrowUp`/`onArrowDown`:

```swift
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
```

And in `keyDown`, add a case:

```swift
        case 48: event.modifierFlags.contains(.shift) ? onBacktab?() : onTab?()  // ⇧tab / tab
```

- [ ] **Step 5: Implement `LayoutRow`**

```swift
// Sources/ZenTerm/LayoutRow.swift
import AppKit

/// One Layout & Motion row: a caption, an editing control (Slider / FieldBox / SegmentedControl),
/// a reset-to-default icon shown only when overridden, and an inline validation message. The
/// control is supplied by the section (which owns its keyboard wiring); the row hosts it and owns
/// the reset stop. Reset is reached with Tab from the control and Left from the reset.
final class LayoutRow: NSView {
    let resetButton = AppButton(variant: .muted, symbol: "arrow.uturn.backward")
    var onReset: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onEsc: (() -> Void)?
    /// Called when Left/⇧Tab leaves the reset icon — the section returns focus to this row's control.
    var onFocusControl: (() -> Void)?

    private let messageLabel = NSTextField(labelWithString: "")

    init(caption: String, control: NSView, note: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let captionStack: NSView
        if let note {
            let noteLabel = NSTextField(labelWithString: note)
            noteLabel.font = .systemFont(ofSize: 10)
            noteLabel.textColor = Theme.current.chrome.ink(alpha: 0.4)
            let stack = NSStackView(views: [label, noteLabel])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .firstBaseline
            captionStack = stack
        } else {
            captionStack = label
        }

        resetButton.isKeyboardFocusable = true
        resetButton.setAccessibilityLabel("Reset to default")
        resetButton.onArrowUp = { [weak self] in self?.onArrowUp?() }
        resetButton.onArrowDown = { [weak self] in self?.onArrowDown?() }
        resetButton.onArrowLeft = { [weak self] in self?.onFocusControl?() }
        resetButton.onEsc = { [weak self] in self?.onEsc?() }
        resetButton.onTap = { [weak self] in self?.onReset?() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [captionStack, spacer, control, resetButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        messageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        messageLabel.textColor = Theme.current.chrome.destructive.nsColor
        messageLabel.isHidden = true

        let stack = NSStackView(views: [controls, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            control.widthAnchor.constraint(equalToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(isOverridden: Bool) { resetButton.isHidden = !isOverridden }
    func focusReset() { if !resetButton.isHidden { window?.makeFirstResponder(resetButton) } }
    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }
}
```

- [ ] **Step 6: Implement `SettingsLayoutSection`**

Mirrors `SettingsKeybindsSection`'s scaffold (flipped doc + `SlimScroller`, grouped rows, 18pt group gaps, `detailStops()`, Reset-all, live write→reload→refresh, per-row reset, error-on-edited-row + rollback). Uses a numeric-knob descriptor table for the 7 CGFloat knobs and explicit construction for `reduce-motion` and the two shell fields.

```swift
// Sources/ZenTerm/SettingsLayoutSection.swift
import AppKit

/// The Layout & Motion settings section: sliders/fields/segmented editors for the chrome layout
/// knobs, motion preference, and shell fields. Writes each edit via `ConfigWriter` scalars (a reset
/// removes the key → falls back to `builtIn`), reloads via `AppConfig`, and refreshes every row.
/// Live-appliable knobs update running windows through the `configDidChange` seam (Task 4); the
/// rest apply to new tabs, labeled as such.
final class SettingsLayoutSection: SettingsSection {
    var navTitle: String { "Layout & Motion" }
    var onExitToNav: (() -> Void)?
    var onClose: (() -> Void)?

    /// A numeric (CGFloat) knob: config key, caption, valid range, control style, and how to read
    /// its value from a resolved config. `builtIn = read(GeneralConfig.builtIn)`; overridden =
    /// `read(.current) != builtIn`. `note` labels new-tab-only knobs.
    private struct NumericKnob {
        enum Style { case slider(step: CGFloat), field }
        let key: String
        let caption: String
        let range: ClosedRange<CGFloat>
        let style: Style
        let note: String?
        let read: (GeneralConfig) -> CGFloat
    }

    private static let numericKnobs: [(String, [NumericKnob])] = [
        (
            "Layout",
            [
                NumericKnob(key: "backdrop-alpha", caption: "Backdrop alpha", range: 0...1,
                    style: .slider(step: 0.02), note: nil, read: { $0.backdropAlpha }),
                NumericKnob(key: "window-gutter", caption: "Window gutter", range: 0...64,
                    style: .field, note: "px", read: { $0.windowGutter }),
                NumericKnob(key: "pane-gap", caption: "Pane gap", range: 0...64,
                    style: .field, note: "px", read: { $0.panelGap }),
                NumericKnob(key: "bottom-drawer-fraction", caption: "Bottom drawer", range: 0.1...0.9,
                    style: .slider(step: 0.01), note: "new tabs", read: { $0.bottomDrawerFraction }),
                NumericKnob(key: "right-drawer-fraction", caption: "Right drawer", range: 0.1...0.9,
                    style: .slider(step: 0.01), note: "new tabs", read: { $0.rightDrawerFraction }),
                NumericKnob(key: "drawer-resize-step", caption: "Drawer resize step", range: 4...400,
                    style: .field, note: "px", read: { $0.drawerResizeStep }),
                NumericKnob(key: "max-drawer-fraction", caption: "Max drawer", range: 0.3...0.95,
                    style: .slider(step: 0.01), note: nil, read: { $0.maxDrawerFraction }),
            ]
        )
    ]

    private let resetAllButton = AppButton(title: "Reset all to defaults", variant: .muted)
    private var rows: [LayoutRow] = []
    private var stops: [NSView] = []  // ordered vertical focus stops: each row's control + Reset-all
    private var controlForKey: [String: NSView] = [:]
    private var scalarKeys: [String] = []  // every key this section owns (for Reset-all)

    func makeDetailView() -> NSView {
        rows = []
        stops = []
        controlForKey = [:]
        scalarKeys = []

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 3
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        var previous: NSView?
        func addGroup(_ title: String, _ build: (NSStackView) -> Void) {
            let caption = NSTextField(labelWithString: title.uppercased())
            caption.font = .systemFont(ofSize: 10, weight: .semibold)
            caption.textColor = Theme.current.chrome.ink(alpha: 0.4)
            rowsStack.addArrangedSubview(caption)
            if let previous { rowsStack.setCustomSpacing(18, after: previous) }
            build(rowsStack)
            previous = rowsStack.arrangedSubviews.last
        }

        // Layout group (numeric knobs).
        for (groupTitle, knobs) in Self.numericKnobs {
            addGroup(groupTitle) { stack in
                for knob in knobs { self.addNumericRow(knob, to: stack) }
            }
        }
        // Motion group (reduce-motion segmented).
        addGroup("Motion") { stack in self.addReduceMotionRow(to: stack) }
        // Shell group (new-tab text fields).
        addGroup("Shell") { stack in self.addShellRows(to: stack) }

        resetAllButton.isKeyboardFocusable = true
        resetAllButton.onArrowUp = { [weak self] in guard let self else { return }
            self.moveFocus(from: self.resetAllButton, delta: -1) }
        resetAllButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        resetAllButton.onEsc = { [weak self] in self?.onClose?() }
        resetAllButton.onTap = { [weak self] in self?.resetAll() }
        rowsStack.addArrangedSubview(resetAllButton)
        if let previous { rowsStack.setCustomSpacing(18, after: previous) }
        stops.append(resetAllButton)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = SlimScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 18),
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -18),
        ])
        refreshRows()
        return scroll
    }

    func detailStops() -> [NSView] { stops }

    // MARK: row builders

    private func addNumericRow(_ knob: NumericKnob, to stack: NSStackView) {
        scalarKeys.append(knob.key)
        let current = knob.read(GeneralConfig.current)
        let control: NSView
        switch knob.style {
        case .slider(let step):
            let slider = Slider(value: current, range: knob.range, step: step) { [weak self] value in
                self?.write(knob.key, LayoutFormat.number(value), row: knob.key)
            }
            control = slider
        case .field:
            let box = FieldBox(placeholder: LayoutFormat.number(knob.read(GeneralConfig.builtIn)))
            box.setText(LayoutFormat.number(current))
            box.onChange = { [weak self] in self?.validateAndWriteNumeric(knob, box: box) }
            control = box
        }
        let row = makeRow(key: knob.key, caption: knob.caption, control: control, note: knob.note)
        wireControlKeyboard(control, row: row)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addReduceMotionRow(to stack: NSStackView) {
        scalarKeys.append("reduce-motion")
        let index = LayoutFormat.reduceMotionIndex(GeneralConfig.current.reduceMotion)
        let segmented = SegmentedControl(options: ["System", "On", "Off"], selectedIndex: index) { [weak self] i in
            self?.write("reduce-motion", LayoutFormat.reduceMotionToken(LayoutFormat.reduceMotion(fromIndex: i)), row: "reduce-motion")
        }
        let row = makeRow(key: "reduce-motion", caption: "Reduce motion", control: segmented, note: nil)
        wireControlKeyboard(segmented, row: row)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addShellRows(to stack: NSStackView) {
        scalarKeys.append(contentsOf: ["shell", "shell-args"])
        let shellBox = FieldBox(placeholder: "login shell")
        shellBox.setText(GeneralConfig.current.shell ?? "")
        shellBox.onChange = { [weak self] in
            let text = shellBox.text.trimmingCharacters(in: .whitespaces)
            self?.writeOrRemove("shell", text.isEmpty ? nil : text, row: "shell")
        }
        let shellRow = makeRow(key: "shell", caption: "Shell", control: shellBox, note: "new tabs")
        wireControlKeyboard(shellBox, row: shellRow)
        stack.addArrangedSubview(shellRow)
        shellRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let argsBox = FieldBox(placeholder: "—")
        argsBox.setText(LayoutFormat.joinArgs(GeneralConfig.current.shellArgs))
        argsBox.onChange = { [weak self] in
            let joined = LayoutFormat.joinArgs(LayoutFormat.splitArgs(argsBox.text))
            self?.writeOrRemove("shell-args", joined.isEmpty ? nil : joined, row: "shell-args")
        }
        let argsRow = makeRow(key: "shell-args", caption: "Shell args", control: argsBox, note: "new tabs")
        wireControlKeyboard(argsBox, row: argsRow)
        stack.addArrangedSubview(argsRow)
        argsRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeRow(key: String, caption: String, control: NSView, note: String?) -> LayoutRow {
        let row = LayoutRow(caption: caption, control: control, note: note)
        row.onReset = { [weak self] in self?.reset(key: key, row: row) }
        row.onArrowUp = { [weak self, weak control] in control.map { self?.moveFocus(from: $0, delta: -1) } }
        row.onArrowDown = { [weak self, weak control] in control.map { self?.moveFocus(from: $0, delta: 1) } }
        row.onEsc = { [weak self] in self?.onClose?() }
        row.onFocusControl = { [weak control] in control?.window?.makeFirstResponder(control) }
        rows.append(row)
        stops.append(control)
        controlForKey[key] = control
        return row
    }

    /// Wire a control's Up/Down (move rows), Tab (→ this row's reset), Left-at-boundary/⇧Tab
    /// (→ nav or prev), and Esc through the row/section. Handles the three control types.
    private func wireControlKeyboard(_ control: NSView, row: LayoutRow) {
        let toReset = { [weak row] in row?.focusReset() }
        switch control {
        case let slider as Slider:
            slider.onArrowUp = { [weak self] in self?.moveFocus(from: slider, delta: -1) }
            slider.onArrowDown = { [weak self] in self?.moveFocus(from: slider, delta: 1) }
            slider.onTab = toReset
            slider.onBacktab = { [weak self] in self?.onExitToNav?() }
            slider.onEsc = { [weak self] in self?.onClose?() }
        case let box as FieldBox:
            box.onArrowUp = { [weak self] in self?.moveFocus(from: box, delta: -1) }
            box.onArrowDown = { [weak self] in self?.moveFocus(from: box, delta: 1) }
            box.onArrowLeft = { [weak self] in self?.onExitToNav?() }  // Left at cursor-start → nav
            box.onTab = toReset
            box.onBacktab = { [weak self] in self?.onExitToNav?() }
            box.onEsc = { [weak self] in self?.onClose?() }
        case let seg as SegmentedControl:
            seg.onArrowUp = { [weak self] in self?.moveFocus(from: seg, delta: -1) }
            seg.onArrowDown = { [weak self] in self?.moveFocus(from: seg, delta: 1) }
            seg.onTab = toReset
            seg.onBacktab = { [weak self] in self?.onExitToNav?() }
        default:
            break
        }
    }

    // MARK: writes

    private func validateAndWriteNumeric(_ knob: NumericKnob, box: FieldBox) {
        guard let value = LayoutFormat.parseNumber(box.text, in: knob.range) else {
            rowFor(knob.key)?.showMessage("Enter a number in \(LayoutFormat.number(knob.range.lowerBound))–\(LayoutFormat.number(knob.range.upperBound)).")
            return
        }
        rowFor(knob.key)?.showMessage(nil)
        write(knob.key, LayoutFormat.number(value), row: knob.key)
    }

    private func write(_ key: String, _ value: String, row: String) { persist({ try ConfigWriter.apply(scalars: [key: value]) }, reportKey: row) }
    private func writeOrRemove(_ key: String, _ value: String?, row: String) {
        if let value { write(key, value, row: row) } else { persist({ try ConfigWriter.apply(removals: [key]) }, reportKey: row) }
    }
    private func reset(key: String, row: LayoutRow) { persist({ try ConfigWriter.apply(removals: [key]) }, reportKey: key) }
    private func resetAll() { persist({ try ConfigWriter.apply(removals: Set(self.scalarKeys)) }, reportKey: nil) }

    /// Run a write, reload, and refresh every row from the new config. On failure, report on the
    /// edited row and rebuild the detail view so controls snap back to disk state.
    private func persist(_ write: () throws -> Void, reportKey: String?) {
        do {
            try write()
        } catch {
            (reportKey.flatMap(rowFor) ?? rows.first)?.showMessage("Couldn't write config: \(error.localizedDescription)")
            return
        }
        AppConfig.reload()
        refreshRows()
    }

    private func refreshRows() {
        for (groupTitle, knobs) in Self.numericKnobs {
            _ = groupTitle
            for knob in knobs {
                let overridden = knob.read(GeneralConfig.current) != knob.read(GeneralConfig.builtIn)
                rowFor(knob.key)?.render(isOverridden: overridden)
                if let slider = controlForKey[knob.key] as? Slider { slider.setValue(knob.read(GeneralConfig.current)) }
                if let box = controlForKey[knob.key] as? FieldBox { box.setText(LayoutFormat.number(knob.read(GeneralConfig.current))) }
            }
        }
        let motion = GeneralConfig.current.reduceMotion
        rowFor("reduce-motion")?.render(isOverridden: motion != GeneralConfig.builtIn.reduceMotion)
        rowFor("shell")?.render(isOverridden: GeneralConfig.current.shell != GeneralConfig.builtIn.shell)
        rowFor("shell-args")?.render(isOverridden: GeneralConfig.current.shellArgs != GeneralConfig.builtIn.shellArgs)
    }

    // MARK: focus

    private func moveFocus(from view: NSView, delta: Int) {
        guard let index = stops.firstIndex(where: { $0 === view }) else { return }
        guard let next = KeyboardFocus.step(from: index, delta: delta, count: stops.count) else { return }
        let target = stops[next]
        target.window?.makeFirstResponder(target)
        let scrollTarget = rows.first { $0.subviews(recursively: target) } ?? target
        scrollTarget.scrollToVisible(scrollTarget.bounds.insetBy(dx: 0, dy: -12))
    }

    private func rowFor(_ key: String) -> LayoutRow? {
        guard let control = controlForKey[key] else { return nil }
        return rows.first { $0.subviews(recursively: control) }
    }
}

private extension NSView {
    /// True if `view` is this view or nested anywhere beneath it — used to map a focused control
    /// back to its row for scroll-into-view and messaging.
    func subviews(recursively view: NSView) -> Bool {
        if view === self { return true }
        return subviews.contains { $0.subviews(recursively: view) }
    }
}
```

- [ ] **Step 7: Register the section in the Settings card nav**

In `Sources/ZenTerm/WindowController.swift`, the `openSettings()` builder currently passes `sections: [SettingsKeybindsSection(capturer: keybindCapturer)]`. Add the new section after it:

```swift
            sections: [
                SettingsKeybindsSection(capturer: keybindCapturer),
                SettingsLayoutSection(),
            ],
```

- [ ] **Step 8: Build, run tests, and manually verify the section renders + edits**

Run: `swift build` (clean), `swift test --filter LayoutWriteTests` (PASS). Then `swift run ZenTerm`:
- ⌘, → the nav shows **Keybinds** and **Layout & Motion**; arrow down to Layout & Motion → its editors render with current values. Editing a slider/field writes to `~/.config/zen-term/config` (verify `cat`); a per-row reset icon appears when a knob differs from default and reverts it on click/Return; Reset-all reverts everything. Invalid field entry (e.g. `999` in gutter) shows the inline range error and doesn't write.
- Keyboard: ↑/↓ move rows; ←/→ nudge a focused slider / move a field cursor / pick a segment; Tab reaches the reset icon; Esc closes.

(Live re-apply to the running window is wired in Task 4 — at this point new values take effect on the next new tab / relaunch, which is expected.)

- [ ] **Step 9: Commit**

```bash
git add Sources/ZenTerm/LayoutRow.swift Sources/ZenTerm/SettingsLayoutSection.swift \
  Sources/ZenTerm/Controls/FieldBox.swift Sources/ZenTerm/Controls/SegmentedControl.swift \
  Sources/ZenTerm/WindowController.swift Tests/ZenTermTests/LayoutWriteTests.swift
git commit -m "Add Layout & Motion settings section (sliders/fields/segmented, live write+reset)"
```

---

### Task 4: Live re-apply seam + config docs

**Files:**
- Modify: `Sources/ZenTerm/AppDelegate.swift:35-39` (config observer also re-applies MotionConfig)
- Modify: `Sources/ZenTerm/WindowController.swift` (store `tint`; add a `configDidChange` observer that re-tints + re-lays-out each `TabController`; remove it in `tearDown`)
- Modify: `Sources/ZenTerm/TabController.swift` (store the four gutter inset constraints; add `reapplyChromeLayout()`)
- Modify: `docs/config/config` (per-knob live-apply notes)

**Interfaces:**
- Consumes: `.configDidChange`, `GeneralConfig.current`, `MotionConfig.apply(_:)`, `ChromeMetrics.windowGutter`.
- Produces: `TabController.reapplyChromeLayout()` (internal); a stored `tint` on `WindowController`.

- [ ] **Step 1: reduce-motion live — extend the AppDelegate observer**

In `AppDelegate.applicationDidFinishLaunching`, the existing `.configDidChange` observer only rebuilds the keymap. Add the motion re-apply:

```swift
        NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.keys.setKeymap(GeneralConfig.current.keymap)
            MotionConfig.apply(GeneralConfig.current.reduceMotion)  // re-install the reduce-motion override
        }
```

- [ ] **Step 2: `TabController` — store gutter constraints + add `reapplyChromeLayout()`**

Store the four content-inset constraints (currently created inline and discarded) as a property, then add an internal re-apply method.

Add the property near the other layout state:

```swift
    /// The four window-gutter content-inset constraints, kept so a config change can re-apply the
    /// gutter to this already-built tab (see `reapplyChromeLayout()`).
    private var gutterConstraints: [NSLayoutConstraint] = []
```

Replace the inline `NSLayoutConstraint.activate([...])` for the content insets (the four `ChromeMetrics.windowGutter` constraints) with a stored-then-activated form:

```swift
        gutterConstraints = [
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ChromeMetrics.windowGutter),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ChromeMetrics.windowGutter),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: ChromeMetrics.windowGutter),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -ChromeMetrics.windowGutter),
        ]
        NSLayoutConstraint.activate(gutterConstraints)
```

Add the re-apply method (near `relayoutPanels()`), updating the gutter constants (leading/top positive, trailing/bottom negative) and re-tiling for `panelGap`:

```swift
    /// Re-apply the live chrome-layout knobs (window gutter, pane gap) to this built tab after a
    /// config change — no relaunch. `relayoutPanels()` re-reads `panelGap`; the gutter constraints
    /// get their new constant. Drawer fractions are intentionally not reset (a hand ⌥-resize owns
    /// the running ratio; the new fraction seeds new tabs).
    func reapplyChromeLayout() {
        let gutter = ChromeMetrics.windowGutter
        for constraint in gutterConstraints {
            constraint.constant = (constraint.constant < 0) ? -gutter : gutter
        }
        relayoutPanels()
        view.layoutSubtreeIfNeeded()
    }
```

- [ ] **Step 3: `WindowController` — store `tint` + observe config changes**

Promote the backdrop `tint` from a local `let` to a stored property so it can be re-tinted:

Add the property (near `container`):

```swift
    /// The base-color tint over the behind-window blur; stored so a `backdrop-alpha` change can
    /// re-tint the running window (see the `configDidChange` observer).
    private let tint = NSView()
```

In the setup where `let tint = NSView(frame: content.bounds)` is created, drop the `let` (assign the stored one) and keep the frame/color/mask lines:

```swift
        tint.frame = content.bounds
        tint.wantsLayer = true
        tint.layer?.backgroundColor =
            Theme.current.chrome.background.nsColor.withAlphaComponent(Self.backdropTintAlpha).cgColor
        tint.autoresizingMask = [.width, .height]
        content.addSubview(tint)
```

Add a stored observer token property and register it during init (after the modal slot is set up), re-tinting and re-laying-out every tab; store the token so `tearDown` can remove it:

```swift
    private var configObserver: NSObjectProtocol?
```

```swift
        configObserver = NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.tint.layer?.backgroundColor =
                Theme.current.chrome.background.nsColor.withAlphaComponent(Self.backdropTintAlpha).cgColor
            for controller in self.controllers.values { controller.reapplyChromeLayout() }
        }
```

In `tearDown()`, remove the observer (alongside the existing capture/poll teardown):

```swift
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
```

- [ ] **Step 4: Build + verify live apply by hand**

Run: `swift build` (clean), then `swift run ZenTerm`:
- ⌘, → Layout & Motion. Drag **backdrop alpha** → the current window's backdrop re-tints immediately. Change **window gutter** / **pane gap** → the current window's content inset + pane tiling update live. Set **reduce motion** to On → the next card open/close is instant (no spring).
- Change **bottom/right drawer** or **shell** → the current tab is unchanged; ⌘T opens a new tab that uses the new value. A hand ⌥-resized drawer keeps its size across the edit.
- Close a window while Settings is open → no crash, no leaked observer (the app keeps running normally).

- [ ] **Step 5: Document per-knob live-apply behavior in `docs/config/config`**

Add short annotations next to each of these keys noting whether an in-app edit applies live or on new tabs: `backdrop-alpha`/`window-gutter`/`pane-gap`/`drawer-resize-step`/`max-drawer-fraction`/`reduce-motion` → "applies live"; `bottom-drawer-fraction`/`right-drawer-fraction`/`shell`/`shell-args` → "applies to new tabs." Keep the existing comment style; don't reformat unrelated lines.

- [ ] **Step 6: `bin/check` + commit**

Run: `bin/check` (fully green). Then:

```bash
git add Sources/ZenTerm/AppDelegate.swift Sources/ZenTerm/WindowController.swift \
  Sources/ZenTerm/TabController.swift docs/config/config
git commit -m "Wire live re-apply for Layout & Motion (backdrop/gutter/gap/reduce-motion)"
```

---

## Task order note

Build **Task 2 before Task 1** (Slider's `restyle()` calls `LayoutFormat.number`), or inline the `%g` format in Task 1 and swap it in Task 2. Tasks 3 and 4 depend on 1+2; Task 4 depends on nothing in 3 except that the section exists to exercise the seam by hand.

## Self-review

- **Spec coverage:** every knob in the spec table has a row builder (numeric table + reduce-motion + shell/shell-args); the three live-apply hooks (MotionConfig, backdrop tint, gutter/gap relayout) are Task 4; the new `Slider` is Task 1; write/reset via `ConfigWriter` is Task 3 + covered by `LayoutWriteTests`; the keyboard model (↑/↓ rows, ←/→ control, Tab→reset, Esc) is wired in Task 3. ✓
- **Type consistency:** `LayoutFormat` signatures match between Task 2 definition and Task 1/3 uses; `NumericKnob.read` reads the exact `GeneralConfig` field names from `GeneralConfig.swift`; `reapplyChromeLayout()` name matches between Task 2 (definition) and Task 3 (call). ✓
- **Ranges** match the parser clamps (Global Constraints). ✓
- **Shared-primitive edits** (`FieldBox`, `SegmentedControl`) are additive default-nil hooks only. ✓
