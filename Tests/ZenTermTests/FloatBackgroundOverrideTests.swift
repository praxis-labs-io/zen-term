import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The float half: a tool float's card follows a background its own program repainted.
///
/// A float is the one host that genuinely needs the `backgroundOverride` **pull**. A persistent
/// float keeps its surface running while hidden but is torn down to that surface, so an OSC 11 it
/// emits in the background reaches a controller with no card to paint. The next open builds a
/// fresh `SurfaceFloatOverlay`, which has to come up already wearing the color rather than on the
/// theme's. Panes and drawers need no pull: their host and surface are created and destroyed
/// together.
///
/// `background-alpha` is pinned rather than inherited, because it decides which view paints the
/// card's interior and an unpinned suite mounting a `SurfaceFloatOverlay` is exactly the shape
/// that caused the cross-suite flakiness.
final class FloatBackgroundOverrideTests: WindowTestCase {
    private var windows: [NSWindow] = []
    private var floatControllers: [ToolFloatController] = []
    private var root = FileManager.default.temporaryDirectory
    private var originalConfig: GeneralConfig!
    private var originalReduceMotion: (() -> Bool)!

    private let osc11 = TerminalColor(red: 0x3B, green: 0x2E, blue: 0x2E)

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
        originalReduceMotion = Motion.isReduceMotionEnabled
        Motion.isReduceMotionEnabled = { true }  // instant present, so the card is mounted on return
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-float-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        floatControllers.forEach { $0.shutdown() }
        floatControllers = []
        windows = []
        Motion.isReduceMotionEnabled = originalReduceMotion
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeFloats() -> (
        floats: ToolFloatController, spawned: () -> [RecordingSurface], host: NSView
    ) {
        var spawned: [RecordingSurface] = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView?.addSubview(host)
        let floats = ToolFloatController(
            presentOverlay: { overlay in
                overlay.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(overlay)
                NSLayoutConstraint.activate([
                    overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    overlay.topAnchor.constraint(equalTo: host.topAnchor),
                    overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                ])
            },
            focusedCWD: { self.root },
            yieldFocus: {},
            restoreFocus: {},
            makeSurface: {
                let surface = RecordingSurface()
                spawned.append(surface)
                return surface
            },
            resolveRepoRoot: { cwd, deliver in deliver(cwd) })
        host.layoutSubtreeIfNeeded()
        windows.append(window)
        floatControllers.append(floats)
        return (floats, { spawned }, host)
    }

    private func spec(_ id: String, persist: ToolFloat.Persistence) -> ToolFloat {
        ToolFloat(
            id: id, order: 0, title: id, icon: ToolFloatParser.defaultIcon, command: id,
            dir: nil, widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: persist, toggle: Chord(command: true, shift: true, key: "j"))
    }

    /// The card actually in the view tree, found by walking it rather than asking the controller.
    private func mountedCard(in host: NSView) -> SurfaceFloatOverlay? {
        host.subviews.compactMap { $0 as? SurfaceFloatOverlay }.last
    }

    private func assertPaints(
        _ card: SurfaceFloatOverlay, _ expected: TerminalColor, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let painted = card.paintedBackgroundForTesting
        let color: NSColor? = painted.fill.flatMap { NSColor(cgColor: $0) } ?? painted.ring
        guard let actual = color?.usingColorSpace(.sRGB) else {
            return XCTFail("the card painted no interior color", file: file, line: line)
        }
        let want = expected.nsColor
        XCTAssertEqual(actual.redComponent, want.redComponent, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, want.greenComponent, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, want.blueComponent, accuracy: 0.01, message, file: file, line: line)
    }

    func test_repaintReachesTheShownCard() throws {
        let (floats, spawned, host) = makeFloats()
        floats.toggle(spec("lazygit", persist: .ephemeral))
        let surface = try XCTUnwrap(spawned().last)
        let card = try XCTUnwrap(mountedCard(in: host))

        floats.surface(surface, backgroundDidChange: osc11)

        assertPaints(card, osc11, "the shown card kept the theme background")
    }

    /// The pull. A persistent float repaints while hidden, so the event lands with no card; the
    /// card built by the next open has to take the color from the surface itself.
    func test_aRepaintWhileHiddenReachesTheCardBuiltOnReopen() throws {
        let (floats, spawned, host) = makeFloats()
        let float = spec("lazygit", persist: .directory)
        floats.toggle(float)
        let surface = try XCTUnwrap(spawned().last)

        floats.close()
        surface.backgroundOverride = osc11  // the program repaints with no card mounted
        floats.toggle(float)

        let reopened = try XCTUnwrap(mountedCard(in: host))
        XCTAssertFalse(surface.terminated, "a persistent float must survive dismissal")
        assertPaints(
            reopened, osc11,
            "the reopened card came back on the theme while its terminal stayed repainted")
    }

    /// A repaint in one float must not reach another float's card.
    func test_repaintDoesNotReachAForeignCard() throws {
        let (floats, spawned, host) = makeFloats()
        floats.toggle(spec("lazygit", persist: .ephemeral))
        let shown = try XCTUnwrap(spawned().last)
        let card = try XCTUnwrap(mountedCard(in: host))
        let stranger = RecordingSurface()

        floats.surface(stranger, backgroundDidChange: osc11)

        XCTAssertFalse(stranger === shown)
        assertPaints(
            card, Theme.current.chrome.background,
            "a surface this controller does not show repainted the card")
    }
}
