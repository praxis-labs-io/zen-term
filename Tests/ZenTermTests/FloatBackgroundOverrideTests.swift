import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class FloatBackgroundOverrideTests: WindowTestCase {
    private var windows: [NSWindow] = []
    private var floatControllers: [ToolFloatController] = []
    private var root = FileManager.default.temporaryDirectory
    private var originalConfig: GeneralConfig!

    private let osc11 = TerminalColor(red: 0x3B, green: 0x2E, blue: 0x2E)

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
        Motion.isReduceMotionEnabled = { true }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-float-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        floatControllers.forEach { $0.shutdown() }
        floatControllers = []
        windows = []
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

    func test_aRepaintWhileHiddenReachesTheCardBuiltOnReopen() throws {
        let (floats, spawned, host) = makeFloats()
        let float = spec("lazygit", persist: .directory)
        floats.toggle(float)
        let surface = try XCTUnwrap(spawned().last)

        floats.close()
        surface.backgroundOverride = osc11
        floats.toggle(float)

        let reopened = try XCTUnwrap(mountedCard(in: host))
        XCTAssertFalse(surface.terminated, "a persistent float must survive dismissal")
        assertPaints(
            reopened, osc11,
            "the reopened card came back on the theme while its terminal stayed repainted")
    }

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
