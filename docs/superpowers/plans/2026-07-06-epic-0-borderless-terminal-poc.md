# Epic 0 — Borderless Terminal PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove a live, PTY-backed shell runs inside a minimal-chrome macOS window — rendered in the rounded/bordered floating pane with gutters — reached only through the `TerminalSurface` seam, with selective keybind interception working.

**Architecture:** A SwiftPM package with two targets: a `TerminalKit` library holding the `TerminalSurface` protocol + its `SwiftTermSurface` conformance (the only target that depends on SwiftTerm), and a `ZenTerm` executable holding the app chrome (window, floating pane, key interception) that depends on `TerminalKit` **only**. The seam is enforced at the module level: the app target cannot `import SwiftTerm` because it doesn't depend on it.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit, SwiftTerm 1.13.0, XCTest. macOS 13+.

## Global Constraints

- **Platform floor:** macOS 13 (`.macOS(.v13)` in Package.swift). SwiftTerm requires macOS 11+; we pin higher for modern AppKit APIs.
- **Dependency pin:** SwiftTerm `from: "1.13.0"` (`https://github.com/migueldeicaza/SwiftTerm.git`).
- **Seam discipline (compile-enforced):** the `ZenTerm` executable target MUST NOT list `SwiftTerm` as a dependency. Only `TerminalKit` depends on SwiftTerm. Any `import SwiftTerm` in `Sources/ZenTerm/` is a plan violation.
- **Canvas color:** Rosé Pine Moon `--canvas` = `#232136` = `NSColor(srgbRed: 0x23/255.0, green: 0x21/255.0, blue: 0x36/255.0, alpha: 1)`. Panel border = `NSColor(white: 1, alpha: 0.08)`. Pane corner radius `12`, gutter `12`.
- **Swift naming:** PascalCase types; one primary type per file; filename matches the type. Public API in `TerminalKit` is `public`. Prefer `type`/`struct`/`final class`; no force-unwraps except documented AppKit `contentView!`.
- **Verified SwiftTerm API (do not re-guess):**
  - `LocalProcessTerminalView(frame: CGRect)` — `open` NSView subclass.
  - `startProcess(executable: String, args: [String], environment: [String]?, execName: String?, currentDirectory: String?)`.
  - `var processDelegate: LocalProcessTerminalViewDelegate?`.
  - `LocalProcessTerminalViewDelegate`: `sizeChanged(source: LocalProcessTerminalView, newCols:, newRows:)`, `setTerminalTitle(source: LocalProcessTerminalView, title:)`, `hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)`, `processTerminated(source: TerminalView, exitCode: Int32?)`.
  - `send(txt: String)`, `getSelection() -> String?`, `scroll(toPosition: Double)`, `terminate()`.
  - `Terminal.getEnvironmentVariables(termName: String?, trueColor: Bool) -> [String]`.
  - Bell / OSC 9 notify / OSC 9;4 progress live on `TerminalDelegate` (`bell`, `notify(source:title:body:)`, `progressReport(source:report:)`) — NOT on `LocalProcessTerminalViewDelegate`. Reaching them is the Task 8 spike, not an assumption.

---

## File Structure

```text
zen-term/
├── Package.swift
├── .gitignore
├── Sources/
│   ├── TerminalKit/
│   │   ├── TerminalSurface.swift          # protocol + config/delegate/progress/notification types
│   │   ├── TerminalSurfaceFactory.swift   # TerminalBackend enum + factory (the swap point)
│   │   ├── EnvBuilder.swift               # KEY=VALUE env merge (pure, tested)
│   │   ├── OSC7.swift                     # cwd string → file URL (pure, tested)
│   │   └── SwiftTermSurface.swift         # the SwiftTerm conformance (only SwiftTerm consumer)
│   └── ZenTerm/
│       ├── main.swift                     # NSApplication bootstrap
│       ├── AppDelegate.swift              # wires window + surface + interceptor + logger
│       ├── HostWindow.swift               # minimal-chrome NSWindow
│       ├── PaneHostView.swift             # rounded/bordered floating pane with gutters
│       ├── KeyInterceptor.swift           # selective local key-event monitor
│       └── ConsoleSurfaceLogger.swift     # delegate → console (title/cwd/exit)
└── Tests/
    └── TerminalKitTests/
        ├── OSC7Tests.swift
        ├── EnvBuilderTests.swift
        └── SeamTests.swift                # protocol coherence via an in-test mock
```

**Testability split (honest):** `TerminalKit`'s pure logic (OSC 7 parsing, env merge, protocol coherence) is TDD'd with XCTest. The AppKit GUI integration (window, floating pane, live shell, key interception, delegate spike) cannot be meaningfully unit-tested — those tasks end with a **manual verification runbook** with exact run commands and precise observable expectations. Pretending to XCTest "a window shows a shell" would be theater.

---

### Task 1: Package scaffolding + SwiftTerm dependency

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/ZenTerm/main.swift` (temporary smoke stub, replaced in Task 5)
- Create: `Sources/TerminalKit/Placeholder.swift` (temporary, deleted in Task 2)

**Interfaces:**
- Produces: a resolvable, buildable SwiftPM package named `ZenTerm` with targets `TerminalKit` (lib, depends on SwiftTerm), `ZenTerm` (exe, depends on TerminalKit), `TerminalKitTests`.

- [ ] **Step 1: Write `.gitignore`**

```gitignore
.build/
.swiftpm/
*.xcodeproj
DerivedData/
.DS_Store
```

- [ ] **Step 2: Write `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZenTerm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
    ],
    targets: [
        .target(
            name: "TerminalKit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .executableTarget(
            name: "ZenTerm",
            dependencies: ["TerminalKit"]   // NOTE: no SwiftTerm — the seam is enforced here.
        ),
        .testTarget(
            name: "TerminalKitTests",
            dependencies: ["TerminalKit"]
        ),
    ]
)
```

- [ ] **Step 3: Write temporary stubs so both targets compile**

`Sources/TerminalKit/Placeholder.swift`:

```swift
// Temporary — replaced by the seam in Task 2.
enum Placeholder {}
```

`Sources/ZenTerm/main.swift`:

```swift
// Temporary smoke stub — replaced by the NSApplication bootstrap in Task 5.
print("zen-term: package scaffolding OK")
```

- [ ] **Step 4: Resolve and build**

Run: `swift build`
Expected: SwiftTerm 1.13.0 (and its transitive deps) resolve and the build succeeds with `Compiling ... Build complete!`. First run downloads the dependency; allow a minute.

- [ ] **Step 5: Smoke-run the executable**

Run: `swift run ZenTerm`
Expected: prints `zen-term: package scaffolding OK` and exits 0.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved .gitignore Sources
git commit -m "chore: scaffold SwiftPM package with SwiftTerm dependency"
```

---

### Task 2: The `TerminalSurface` seam (protocol + types)

**Files:**
- Create: `Sources/TerminalKit/TerminalSurface.swift`
- Delete: `Sources/TerminalKit/Placeholder.swift`
- Create: `Tests/TerminalKitTests/SeamTests.swift`

**Interfaces:**
- Produces:
  - `struct TerminalSurfaceConfig` — `init(command: String? = nil, args: [String] = [], workingDirectory: URL? = nil, environment: [String: String] = [:], fontSize: CGFloat? = nil)`.
  - `struct TerminalNotification { var title: String; var body: String }`.
  - `struct TerminalProgress { enum State { case running, paused, error, indeterminate }; var state: State; var fraction: Double? }`.
  - `protocol TerminalSurfaceDelegate: AnyObject` with default no-op implementations for every method.
  - `protocol TerminalSurface: AnyObject { var view: NSView { get }; var delegate: TerminalSurfaceDelegate? { get set }; var title: String { get }; var isFocused: Bool { get }; func start(_:); func focus(); func terminate(); func paste(_:); func copySelection() -> String?; func scrollToBottom() }`.

- [ ] **Step 1: Write the failing test** (`Tests/TerminalKitTests/SeamTests.swift`)

```swift
import XCTest
import AppKit
@testable import TerminalKit

/// A minimal in-test surface proving the protocol is coherent and usable
/// without any backend. If this compiles and routes a delegate call, the
/// seam's shape is sound.
private final class SpySurface: TerminalSurface {
    let view = NSView()
    weak var delegate: TerminalSurfaceDelegate?
    var title = "spy"
    var isFocused = false
    private(set) var started = false

    func start(_ config: TerminalSurfaceConfig) {
        started = true
        delegate?.surface(self, titleDidChange: "spy-started")
    }
    func focus() { isFocused = true }
    func terminate() {}
    func paste(_ text: String) {}
    func copySelection() -> String? { nil }
    func scrollToBottom() {}
}

private final class RecordingDelegate: TerminalSurfaceDelegate {
    var lastTitle: String?
    func surface(_ s: TerminalSurface, titleDidChange title: String) { lastTitle = title }
    // All other methods use the protocol's default no-op implementations.
}

final class SeamTests: XCTestCase {
    func test_startRoutesTitleThroughDelegate() {
        let surface = SpySurface()
        let recorder = RecordingDelegate()
        surface.delegate = recorder

        surface.start(TerminalSurfaceConfig())

        XCTAssertTrue(surface.started)
        XCTAssertEqual(recorder.lastTitle, "spy-started")
    }

    func test_configDefaults() {
        let config = TerminalSurfaceConfig()
        XCTAssertNil(config.command)
        XCTAssertTrue(config.args.isEmpty)
        XCTAssertTrue(config.environment.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SeamTests`
Expected: FAIL — compile error, `TerminalSurface`, `TerminalSurfaceConfig`, `TerminalSurfaceDelegate` are undefined.

- [ ] **Step 3: Write the seam** (`Sources/TerminalKit/TerminalSurface.swift`) and delete the placeholder

```swift
import AppKit

/// Spawn parameters for a terminal-backed leaf.
public struct TerminalSurfaceConfig {
    public var command: String?
    public var args: [String]
    public var workingDirectory: URL?
    public var environment: [String: String]
    public var fontSize: CGFloat?

    public init(
        command: String? = nil,
        args: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        fontSize: CGFloat? = nil
    ) {
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.fontSize = fontSize
    }
}

public struct TerminalNotification {
    public var title: String
    public var body: String
    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public struct TerminalProgress {
    public enum State { case running, paused, error, indeterminate }
    public var state: State
    public var fraction: Double?
    public init(state: State, fraction: Double? = nil) {
        self.state = state
        self.fraction = fraction
    }
}

/// Events flowing OUT of a surface, up into the chrome. Each backend translates
/// its native callbacks into these.
public protocol TerminalSurfaceDelegate: AnyObject {
    func surface(_ s: TerminalSurface, titleDidChange title: String)
    func surface(_ s: TerminalSurface, cwdDidChange url: URL)
    func surfaceDidRingBell(_ s: TerminalSurface)
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification)
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?)
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?)
    func surfaceWantsClose(_ s: TerminalSurface)
}

/// Default no-ops so a consumer implements only the events it cares about.
public extension TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, titleDidChange title: String) {}
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {}
    func surfaceDidRingBell(_ s: TerminalSurface) {}
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {}
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?) {}
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {}
    func surfaceWantsClose(_ s: TerminalSurface) {}
}

/// The leaf contract. A backend is anything that can BE a terminal in our chrome.
public protocol TerminalSurface: AnyObject {
    var view: NSView { get }
    var delegate: TerminalSurfaceDelegate? { get set }
    var title: String { get }
    var isFocused: Bool { get }

    func start(_ config: TerminalSurfaceConfig)
    func focus()
    func terminate()

    func paste(_ text: String)
    func copySelection() -> String?
    func scrollToBottom()
}
```

Then: `rm Sources/TerminalKit/Placeholder.swift`

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SeamTests`
Expected: PASS — 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TerminalKit/TerminalSurface.swift Tests/TerminalKitTests/SeamTests.swift
git rm Sources/TerminalKit/Placeholder.swift
git commit -m "feat: add TerminalSurface seam (protocol + config/delegate types)"
```

---

### Task 3: Pure helpers — OSC 7 cwd parsing + env merge

**Files:**
- Create: `Sources/TerminalKit/OSC7.swift`
- Create: `Sources/TerminalKit/EnvBuilder.swift`
- Create: `Tests/TerminalKitTests/OSC7Tests.swift`
- Create: `Tests/TerminalKitTests/EnvBuilderTests.swift`

**Interfaces:**
- Produces:
  - `enum OSC7 { static func fileURL(from raw: String) -> URL? }` — builds a file URL from an OSC 7 payload (plain path or `file://` URL); returns nil for empty input.
  - `enum EnvBuilder { static func merged(base: [String], overrides: [String: String]) -> [String] }` — merges `KEY=VALUE` overrides into a base env array, overrides winning; leftover overrides appended in sorted key order for determinism.

- [ ] **Step 1: Write the failing tests**

`Tests/TerminalKitTests/OSC7Tests.swift`:

```swift
import XCTest
@testable import TerminalKit

final class OSC7Tests: XCTestCase {
    func test_plainPath() {
        XCTAssertEqual(OSC7.fileURL(from: "/Users/me/dev")?.path, "/Users/me/dev")
    }

    func test_pathWithSpaces() {
        XCTAssertEqual(OSC7.fileURL(from: "/Users/me/my project")?.path, "/Users/me/my project")
    }

    func test_fileURLScheme() {
        XCTAssertEqual(OSC7.fileURL(from: "file:///Users/me/dev")?.path, "/Users/me/dev")
    }

    func test_fileURLSchemeWithPercentEncodedSpace() {
        XCTAssertEqual(OSC7.fileURL(from: "file:///Users/me/my%20project")?.path, "/Users/me/my project")
    }

    func test_emptyIsNil() {
        XCTAssertNil(OSC7.fileURL(from: "   "))
    }
}
```

`Tests/TerminalKitTests/EnvBuilderTests.swift`:

```swift
import XCTest
@testable import TerminalKit

final class EnvBuilderTests: XCTestCase {
    func test_noOverridesReturnsBaseUnchanged() {
        let base = ["PATH=/usr/bin", "TERM=xterm"]
        XCTAssertEqual(EnvBuilder.merged(base: base, overrides: [:]), base)
    }

    func test_overrideReplacesExistingKeyInPlace() {
        let base = ["PATH=/usr/bin", "TERM=xterm"]
        let result = EnvBuilder.merged(base: base, overrides: ["TERM": "xterm-256color"])
        XCTAssertEqual(result, ["PATH=/usr/bin", "TERM=xterm-256color"])
    }

    func test_newKeysAppendedInSortedOrder() {
        let base = ["PATH=/usr/bin"]
        let result = EnvBuilder.merged(base: base, overrides: ["ZED": "1", "ABLE": "1"])
        XCTAssertEqual(result, ["PATH=/usr/bin", "ABLE=1", "ZED=1"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OSC7Tests --filter EnvBuilderTests`
Expected: FAIL — `OSC7` and `EnvBuilder` are undefined.

- [ ] **Step 3: Write `OSC7.swift`**

```swift
import Foundation

/// Parses OSC 7 ("current working directory") payloads into file URLs.
public enum OSC7 {
    public static func fileURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("file://") {
            // Decode host + percent-encoding via URL, then rebuild a clean file URL.
            guard let parsed = URL(string: trimmed), parsed.isFileURL else { return nil }
            return URL(fileURLWithPath: parsed.path)
        }
        // A bare path — never URL(string:), which drops paths containing spaces.
        return URL(fileURLWithPath: trimmed)
    }
}
```

- [ ] **Step 4: Write `EnvBuilder.swift`**

```swift
import Foundation

/// Builds the child-process environment by layering overrides over a base.
public enum EnvBuilder {
    public static func merged(base: [String], overrides: [String: String]) -> [String] {
        guard !overrides.isEmpty else { return base }

        var remaining = overrides
        var result: [String] = []
        result.reserveCapacity(base.count + overrides.count)

        for entry in base {
            let key = String(entry.prefix { $0 != "=" })
            if let value = remaining.removeValue(forKey: key) {
                result.append("\(key)=\(value)")
            } else {
                result.append(entry)
            }
        }
        for (key, value) in remaining.sorted(by: { $0.key < $1.key }) {
            result.append("\(key)=\(value)")
        }
        return result
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter OSC7Tests --filter EnvBuilderTests`
Expected: PASS — all 8 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/TerminalKit/OSC7.swift Sources/TerminalKit/EnvBuilder.swift Tests/TerminalKitTests/OSC7Tests.swift Tests/TerminalKitTests/EnvBuilderTests.swift
git commit -m "feat: add OSC7 cwd parsing and env-merge helpers"
```

---

### Task 4: `SwiftTermSurface` conformance + factory

**Files:**
- Create: `Sources/TerminalKit/SwiftTermSurface.swift`
- Create: `Sources/TerminalKit/TerminalSurfaceFactory.swift`
- Modify: `Tests/TerminalKitTests/SeamTests.swift` (add a factory construction test)

**Interfaces:**
- Consumes: `TerminalSurface`, `TerminalSurfaceConfig`, `TerminalSurfaceDelegate` (Task 2); `OSC7.fileURL(from:)`, `EnvBuilder.merged(base:overrides:)` (Task 3).
- Produces:
  - `final class SwiftTermSurface: NSObject, TerminalSurface` — wraps `LocalProcessTerminalView`, maps `processDelegate` callbacks to `TerminalSurfaceDelegate`.
  - `enum TerminalBackend { case swiftTerm }` (`.ghostty` added in a later epic).
  - `enum TerminalSurfaceFactory { static var backend: TerminalBackend; static func make() -> TerminalSurface }`.

- [ ] **Step 1: Write `SwiftTermSurface.swift`**

```swift
import AppKit
import SwiftTerm

/// SwiftTerm-backed terminal surface. The only type in TerminalKit that touches
/// SwiftTerm. Bell / notify / progress live on TerminalDelegate (below this view
/// delegate) and are the subject of the Task 8 spike, not wired here.
public final class SwiftTermSurface: NSObject, TerminalSurface {
    private let term = LocalProcessTerminalView(frame: .zero)
    private var lastTitle = ""

    public weak var delegate: TerminalSurfaceDelegate?

    public var view: NSView { term }
    public var title: String { lastTitle }
    public var isFocused: Bool { term.window?.firstResponder === term }

    public override init() {
        super.init()
        term.processDelegate = self
    }

    public func start(_ config: TerminalSurfaceConfig) {
        let base = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let environment = EnvBuilder.merged(base: base, overrides: config.environment)
        let shell = config.command
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"

        term.startProcess(
            executable: shell,
            args: config.args,
            environment: environment,
            execName: nil,
            currentDirectory: config.workingDirectory?.path
        )
    }

    public func focus() { term.window?.makeFirstResponder(term) }
    public func terminate() { term.terminate() }
    public func paste(_ text: String) { term.send(txt: text) }
    public func copySelection() -> String? { term.getSelection() }
    public func scrollToBottom() { term.scroll(toPosition: 1) }
}

extension SwiftTermSurface: LocalProcessTerminalViewDelegate {
    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        lastTitle = title
        delegate?.surface(self, titleDidChange: title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = OSC7.fileURL(from: directory) else { return }
        delegate?.surface(self, cwdDidChange: url)
    }

    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        delegate?.surfaceDidExit(self, code: exitCode)
    }
}
```

- [ ] **Step 2: Write `TerminalSurfaceFactory.swift`**

```swift
/// The one swap point. Chrome only ever calls `TerminalSurfaceFactory.make()`.
public enum TerminalBackend {
    case swiftTerm
    // case ghostty  — added when backend B (libghostty) lands in a later epic.
}

public enum TerminalSurfaceFactory {
    public static var backend: TerminalBackend = .swiftTerm

    public static func make() -> TerminalSurface {
        switch backend {
        case .swiftTerm:
            return SwiftTermSurface()
        }
    }
}
```

- [ ] **Step 3: Add the factory construction test to `SeamTests.swift`**

Append this method inside `final class SeamTests`:

```swift
    func test_factoryMakesASwiftTermSurfaceView() {
        let surface = TerminalSurfaceFactory.make()
        // The factory returns a live surface whose view is an NSView the chrome
        // can place. We construct only — starting a process is out of unit scope.
        XCTAssertTrue(surface is SwiftTermSurface)
        XCTAssertNotNil(surface.view.superclass) // it is an NSView
    }
```

- [ ] **Step 4: Build and run all TerminalKit tests**

Run: `swift test`
Expected: PASS — all prior tests plus `test_factoryMakesASwiftTermSurfaceView`. If the factory test fails to construct an `NSView` under headless `swift test`, move that single assertion to Task 5's manual runbook and leave a note; the `swift build` compile is the hard gate here.

- [ ] **Step 5: Commit**

```bash
git add Sources/TerminalKit/SwiftTermSurface.swift Sources/TerminalKit/TerminalSurfaceFactory.swift Tests/TerminalKitTests/SeamTests.swift
git commit -m "feat: add SwiftTermSurface conformance and backend factory"
```

---

### Task 5: NSApplication bootstrap + minimal-chrome window + live shell

**Files:**
- Modify (replace): `Sources/ZenTerm/main.swift`
- Create: `Sources/ZenTerm/AppDelegate.swift`
- Create: `Sources/ZenTerm/HostWindow.swift`
- Create: `Sources/ZenTerm/ConsoleSurfaceLogger.swift`

**Interfaces:**
- Consumes: `TerminalSurfaceFactory.make()`, `TerminalSurfaceConfig`, `TerminalSurface`, `TerminalSurfaceDelegate` (from TerminalKit).
- Produces: a runnable app that opens a minimal-chrome window containing a live shell (edge-to-edge for now; the floating pane arrives in Task 6), logging title/cwd/exit to the console.

- [ ] **Step 1: Write `HostWindow.swift`**

```swift
import AppKit

/// Minimal-chrome window: a titled window with a hidden/transparent title bar and
/// full-size content view. NOT `.borderless` — we keep free key-window, drag, and
/// resize behavior. This is the low-effort path to minimal chrome.
final class HostWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = NSColor(srgbRed: 0x23 / 255.0, green: 0x21 / 255.0, blue: 0x36 / 255.0, alpha: 1)
        // Traffic lights stay visible for PoC usability. To go fully chromeless,
        // hide each: standardWindowButton(.closeButton)?.isHidden = true (etc).
    }
}
```

- [ ] **Step 2: Write `ConsoleSurfaceLogger.swift`**

```swift
import Foundation
import TerminalKit

/// Prints the delegate events Epic 0 must observe. Other delegate methods use the
/// protocol's default no-ops.
final class ConsoleSurfaceLogger: TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, titleDidChange title: String) {
        print("[title] \(title)")
    }
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {
        print("[cwd] \(url.path)")
    }
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        print("[exit] code=\(code.map(String.init) ?? "nil")")
    }
}
```

- [ ] **Step 3: Write `AppDelegate.swift`**

```swift
import AppKit
import TerminalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: HostWindow!
    private let surface = TerminalSurfaceFactory.make()
    private let logger = ConsoleSurfaceLogger()

    func applicationDidFinishLaunching(_ notification: Notification) {
        surface.delegate = logger

        window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560))
        let content = window.contentView!

        // Task 5: place the terminal edge-to-edge. Task 6 wraps it in PaneHostView.
        let terminalView = surface.view
        terminalView.frame = content.bounds
        terminalView.autoresizingMask = [.width, .height]
        content.addSubview(terminalView)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        surface.start(TerminalSurfaceConfig())
        surface.focus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
```

- [ ] **Step 4: Replace `main.swift` with the bootstrap**

```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!` with no errors. Confirm the seam held: `swift build` must not report `SwiftTerm` as a dependency of the `ZenTerm` target (it isn't in Package.swift).

- [ ] **Step 6: Manual verification runbook**

Run: `swift run ZenTerm`
Observe and confirm each:
- A window appears, centered, with a hidden title bar (no title text, transparent titlebar area) and the dark `#232136` background. Traffic-light buttons are present.
- A live shell prompt renders and blinks. Typing `ls` then Return shows real directory output. `echo $TERM` prints `xterm-256color`.
- The terminal has keyboard focus immediately (you can type without clicking).
- In the terminal, run `cd /tmp` — the console running `swift run` prints a `[cwd] /private/tmp` (or `/tmp`) line (proves OSC 7 → delegate). Note: cwd reporting requires shell integration that emits OSC 7; if your shell doesn't, run `printf '\e]7;file://%s%s\a' "$HOSTNAME" "$PWD"` to emit it manually and confirm the `[cwd]` log fires.
- Exit the shell with `exit` — the console prints `[exit] code=0` and the app terminates.

- [ ] **Step 7: Commit**

```bash
git add Sources/ZenTerm
git commit -m "feat: minimal-chrome window hosting a live shell via the seam"
```

---

### Task 6: Floating pane host view (rounded, bordered, gutters)

**Files:**
- Create: `Sources/ZenTerm/PaneHostView.swift`
- Modify: `Sources/ZenTerm/AppDelegate.swift` (wrap the surface in `PaneHostView`)

**Interfaces:**
- Consumes: an `NSView` (the surface's view).
- Produces: `final class PaneHostView: NSView` — draws the canvas, insets a rounded/bordered pane by the gutter, and hosts the content view inside it edge-to-edge.

- [ ] **Step 1: Write `PaneHostView.swift`**

```swift
import AppKit

/// The single floating pane: canvas background, a rounded + bordered pane inset by
/// the gutter, hosting `content`. This is the one-pane seed of the split canvas
/// that Epic 1 generalizes; the dynamic focus halo is deferred to Epic 1.
final class PaneHostView: NSView {
    private let gutter: CGFloat = 12

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0x23 / 255.0, green: 0x21 / 255.0, blue: 0x36 / 255.0, alpha: 1).cgColor

        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.cornerRadius = 12
        pane.layer?.masksToBounds = true          // clip terminal content to rounded corners
        pane.layer?.borderWidth = 1
        pane.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        pane.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pane)

        content.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(content)

        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            pane.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            pane.topAnchor.constraint(equalTo: topAnchor, constant: gutter),
            pane.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -gutter),

            content.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            content.topAnchor.constraint(equalTo: pane.topAnchor),
            content.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
```

- [ ] **Step 2: Update `AppDelegate.applicationDidFinishLaunching` to use the pane**

Replace the Task 5 "place the terminal edge-to-edge" block:

```swift
        // Task 5: place the terminal edge-to-edge. Task 6 wraps it in PaneHostView.
        let terminalView = surface.view
        terminalView.frame = content.bounds
        terminalView.autoresizingMask = [.width, .height]
        content.addSubview(terminalView)
```

with:

```swift
        let pane = PaneHostView(content: surface.view)
        pane.frame = content.bounds
        pane.autoresizingMask = [.width, .height]
        content.addSubview(pane)
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Manual verification runbook**

Run: `swift run ZenTerm`
Observe and confirm:
- The terminal is no longer edge-to-edge: there is a visible ~12pt gutter of canvas around a rounded-corner, thin-bordered pane holding the shell.
- The rounded corners clip the terminal content (no square terminal corners poking past the radius).
- Resizing the window keeps the gutter even on all sides and the pane re-rounds correctly.
- The shell still runs, types, and is focused as in Task 5.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/PaneHostView.swift Sources/ZenTerm/AppDelegate.swift
git commit -m "feat: host the shell in a rounded floating pane with gutters"
```

---

### Task 7: Selective key interception

**Files:**
- Create: `Sources/ZenTerm/KeyInterceptor.swift`
- Modify: `Sources/ZenTerm/AppDelegate.swift` (start the interceptor, handle chords)

**Interfaces:**
- Consumes: `NSApp`, the window, the surface.
- Produces: `final class KeyInterceptor` — a local key-down monitor that consumes a small reserved allowlist (`⌘W`, `⌘K`) and passes everything else (notably `Ctrl+H`) through to the terminal.

- [ ] **Step 1: Write `KeyInterceptor.swift`**

```swift
import AppKit

/// Selective global interception: consume a small reserved allowlist of chrome
/// chords, pass everything else through to the PTY. This is the mechanism behind
/// the "don't steal Ctrl+hjkl from nvim" rule — un-reserved chords are returned
/// untouched so the terminal (and the program inside it) receives them.
final class KeyInterceptor {
    enum ReservedChord { case close, logProbe }

    var onReservedChord: ((ReservedChord) -> Void)?
    private var monitor: Any?

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()

            // Reserved allowlist — consume (return nil), never reaches the terminal.
            if flags == .command, key == "w" {
                self.onReservedChord?(.close)
                return nil
            }
            if flags == .command, key == "k" {
                self.onReservedChord?(.logProbe)
                return nil
            }

            // Everything else — including Ctrl+H — passes straight through.
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
```

- [ ] **Step 2: Wire it into `AppDelegate`**

Add a stored property:

```swift
    private let keys = KeyInterceptor()
```

At the end of `applicationDidFinishLaunching`, after `surface.focus()`:

```swift
        keys.onReservedChord = { [weak self] chord in
            switch chord {
            case .logProbe:
                print("[reserved] ⌘K intercepted by chrome — did NOT reach the PTY")
            case .close:
                print("[reserved] ⌘W intercepted by chrome")
                self?.surface.terminate()
                self?.window.close()
            }
        }
        keys.start()
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Manual verification runbook**

Run: `swift run ZenTerm`
Confirm both halves of selective interception:
- **Reserved chord consumed:** press `⌘K`. The console prints `[reserved] ⌘K intercepted by chrome — did NOT reach the PTY`, and the terminal shows no `^K` / no clear — proof the chrome caught it first.
- **Un-reserved chord passes through:** in the shell, type `abc`, then press `Ctrl+H`. One character is deleted (`Ctrl+H` is backspace at the PTY) — proof the chord reached the terminal untouched, exactly as `Ctrl+hjkl` must for nvim.
- **Close chord:** press `⌘W`. The console prints `[reserved] ⌘W intercepted by chrome`, the shell terminates, and the window closes.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/KeyInterceptor.swift Sources/ZenTerm/AppDelegate.swift
git commit -m "feat: selective key interception (reserve chrome chords, pass the rest)"
```

---

### Task 8: Delegate spike — bell / OSC 9 notify / OSC 9;4 progress

**Goal:** Empirically determine whether bell, OSC 9 desktop notifications, and OSC 9;4 progress can be surfaced through a `LocalProcessTerminalView` subclass, and document the result — de-risking Epic 4's toast story with evidence instead of assumption. Time-boxed: if a mechanism doesn't dispatch, record that and stop.

**Files:**
- Create: `Sources/TerminalKit/ProbeTerminalView.swift` (a `LocalProcessTerminalView` subclass attempting the overrides)
- Modify: `Sources/TerminalKit/SwiftTermSurface.swift` (use the probe subclass; forward what works)
- Create: `docs/superpowers/notes/epic-0-delegate-spike.md` (findings)
- Modify: `docs/superpowers/specs/2026-07-06-chrome-architecture-design.md` (replace the OSC 9;4 open question with the empirical result)

**Interfaces:**
- Consumes: SwiftTerm's `TerminalDelegate` methods `bell(source:)`, `notify(source:title:body:)`, `progressReport(source:report:)` and `Terminal.ProgressReport`.
- Produces: whichever of `surfaceDidRingBell`, `surface(_:didPostNotification:)`, `surface(_:progressDidChange:)` prove deliverable, wired into `SwiftTermSurface`.

- [ ] **Step 1: Write `ProbeTerminalView.swift` attempting the overrides**

```swift
import AppKit
import SwiftTerm

/// Probes whether the below-view-delegate callbacks (bell / notify / progress)
/// can be intercepted by subclassing. `onBell` / `onNotify` / `onProgress` fire
/// only if the override actually receives dispatch — that is the experiment.
final class ProbeTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?
    var onNotify: ((String, String) -> Void)?
    var onProgress: ((Terminal.ProgressReport) -> Void)?

    // These are TerminalDelegate / TerminalViewDelegate requirements. Whether a
    // subclass method receives dispatch is exactly what the spike measures.
    override func bell(source: TerminalView) {
        onBell?()
        super.bell(source: source)
    }

    func notify(source: Terminal, title: String, body: String) {
        onNotify?(title, body)
    }

    func progressReport(source: Terminal, report: Terminal.ProgressReport) {
        onProgress?(report)
    }
}
```

Note: if any `override`/method signature above fails to compile (e.g. `bell` is not overridable, or the `Terminal`-delegate methods aren't witnessable from a subclass), that is itself a finding — record it in Step 4 and remove the offending member. Do not force it with casts.

- [ ] **Step 2: Wire the probe into `SwiftTermSurface`**

Change the stored terminal from `LocalProcessTerminalView` to `ProbeTerminalView`:

```swift
    private let term = ProbeTerminalView(frame: .zero)
```

In `init`, after `term.processDelegate = self`, forward whatever compiled:

```swift
        term.onBell = { [weak self] in
            guard let self else { return }
            self.delegate?.surfaceDidRingBell(self)
        }
        term.onNotify = { [weak self] title, body in
            guard let self else { return }
            self.delegate?.surface(self, didPostNotification: TerminalNotification(title: title, body: body))
        }
        term.onProgress = { [weak self] report in
            guard let self else { return }
            self.delegate?.surface(self, progressDidChange: Self.map(report))
        }
```

Add the mapping helper to `SwiftTermSurface`:

```swift
    private static func map(_ report: Terminal.ProgressReport) -> TerminalProgress? {
        let fraction = report.progress.map { Double($0) / 100.0 }
        switch report.state {
        case .none:    return nil
        case .set:     return TerminalProgress(state: .running, fraction: fraction)
        case .error:   return TerminalProgress(state: .error, fraction: fraction)
        case .indeterminate: return TerminalProgress(state: .indeterminate, fraction: nil)
        case .paused:  return TerminalProgress(state: .paused, fraction: fraction)
        @unknown default: return nil
        }
    }
```

Note: `Terminal.ProgressReportState` cases must be matched to the real enum found at `Terminal.swift` (`ProgressReportState`). Verify the exact case names when implementing (`grep -n "enum ProgressReportState" -A6` in the SwiftTerm checkout) and adjust the switch to the actual cases — do not invent case names.

- [ ] **Step 3: Add console logging for the probe and build**

In `ConsoleSurfaceLogger`, add:

```swift
    func surfaceDidRingBell(_ s: TerminalSurface) {
        print("[bell]")
    }
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {
        print("[notify] \(n.title): \(n.body)")
    }
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?) {
        print("[progress] \(p.map { "\($0.state) \($0.fraction ?? -1)" } ?? "cleared")")
    }
```

Run: `swift build`
Expected: `Build complete!` (or a documented compile finding per Step 1's note).

- [ ] **Step 4: Run the probe and record findings**

Run: `swift run ZenTerm`, then in the shell emit each sequence and note whether the console logs it:

```bash
printf '\a'                       # bell           → expect [bell]?
printf '\e]9;hello from zen\a'    # OSC 9 notify    → expect [notify]?
printf '\e]9;4;1;40\a'            # OSC 9;4 progress (state 1, 40%) → expect [progress]?
printf '\e]9;4;0;0\a'            # OSC 9;4 clear    → expect [progress] cleared?
```

Write `docs/superpowers/notes/epic-0-delegate-spike.md` recording, for each of bell / notify / progress: **reachable? yes/no**, the mechanism that worked (subclass override vs not), and any code needed. State plainly which of the three Epic 4 depends on are confirmed available.

- [ ] **Step 5: Update the spec's open question with the result**

In `docs/superpowers/specs/2026-07-06-chrome-architecture-design.md`, replace the Epic 0 open-question bullet about "Whether OSC 9;4 progress surfaces cleanly from SwiftTerm..." with the empirical finding (link to the spike note). If progress is NOT reachable by subclass, note the fallback (upstream `TerminalView` hook / fork) and flag it as an Epic 4 risk.

- [ ] **Step 6: Commit**

```bash
git add Sources/TerminalKit/ProbeTerminalView.swift Sources/TerminalKit/SwiftTermSurface.swift Sources/ZenTerm/ConsoleSurfaceLogger.swift docs/superpowers/notes/epic-0-delegate-spike.md docs/superpowers/specs/2026-07-06-chrome-architecture-design.md
git commit -m "spike: probe bell/notify/progress reachability; document findings"
```

---

## Definition of Done (Epic 0)

All must hold, matching the spec's DoD:

- [ ] Live default shell runs in the minimal-chrome window, inside the rounded/bordered floating pane with gutters; typing, output, and resize behave; the window is key and the terminal is first responder. (Tasks 5–6)
- [ ] The terminal is reached **only** through `TerminalSurfaceFactory.make()`; the `ZenTerm` target has no SwiftTerm dependency and no `import SwiftTerm`. (Tasks 1, 4)
- [ ] One reserved chord (`⌘K`) is intercepted before the terminal, and `Ctrl+H` reaches the PTY. (Task 7)
- [ ] Delegate events (title, cwd, exit) are observed in the console. (Task 5)
- [ ] SwiftTerm accessor/delegate names verified against the live API (done during planning; re-confirmed by a green build). (Task 4)
- [ ] Bell/notify/progress reachability is documented with evidence. (Task 8)

## Self-Review Notes

- **Spec coverage:** every Epic 0 "Scope (in)" item maps to a task — protocol+types → T2; SwiftTermSurface → T4; minimal-chrome window → T5; single floating pane → T6; keybind interception → T7; delegate logging → T5, spike → T8.
- **Type consistency:** `TerminalSurface`, `TerminalSurfaceConfig`, `TerminalSurfaceDelegate`, `TerminalSurfaceFactory.make()`, `EnvBuilder.merged(base:overrides:)`, `OSC7.fileURL(from:)` are used identically across tasks.
- **Known verification-time checks the implementer must not skip:** the exact `ProgressReportState` case names (Task 8 Step 2) and the possibility that `bell`/`notify`/`progressReport` are not subclass-dispatchable (Task 8 Step 1) — both are explicitly flagged as findings, not assumptions.
