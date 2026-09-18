import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// A hidden float holding an agent used to ask for you silently: an OS banner, but never a mark in the window.
@MainActor
final class FloatAttentionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-float-attention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = GeneralConfig.builtIn
        config.floats = [Self.spec("btop")]
        GeneralConfig.setCurrentForTesting(config)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private static func spec(_ id: String) -> ToolFloat {
        ToolFloat(
            id: id, order: 0, title: id, icon: ToolFloatParser.defaultIcon, command: id, dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false, persist: .window,
            toggle: Chord(command: true, shift: true, key: "b"))
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.mountAndStart()
        controller = c
        return c
    }

    private func floatSurface() throws -> RecordingSurface {
        try XCTUnwrap(spawned.first { $0.lastConfig?.args == ["-l", "-i", "-c", "btop"] })
    }

    private func notify(_ surface: RecordingSurface, _ body: String) {
        surface.delegate?.surface(
            surface, didPostNotification: TerminalNotification(title: "btop", body: body))
        drainMainQueue()
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func toastViews(_ c: WindowController) -> [ToastView] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? ToastView }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    func test_aHiddenFloatAsking_marksTheWindow() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let surface = try floatSurface()
        c.handle(.toggleToolFloat("btop"))

        notify(surface, "needs input")

        XCTAssertEqual(c.windowAttentionForTesting, .waiting)
    }

    func test_aHiddenFloatAsking_raisesACardNamedAfterTheFloat() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let surface = try floatSurface()
        c.handle(.toggleToolFloat("btop"))

        notify(surface, "needs input")

        let copy = toastViews(c).flatMap { descendants(of: $0) }
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(copy.contains("btop"), "the card names the float, not its host tab")
        XCTAssertTrue(copy.contains("needs input"))
    }

    func test_aFloatYouAreLookingAt_asksForNothing() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let surface = try floatSurface()

        notify(surface, "needs input")

        XCTAssertEqual(
            c.windowAttentionForTesting, .idle,
            "the float is open in front of you, so it is not asking")
        XCTAssertTrue(toastViews(c).isEmpty)
    }

    func test_showingTheFloatAgain_answersIt() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let surface = try floatSurface()
        c.handle(.toggleToolFloat("btop"))
        notify(surface, "needs input")
        XCTAssertEqual(c.windowAttentionForTesting, .waiting)

        c.handle(.toggleToolFloat("btop"))
        drainMainQueue()

        XCTAssertEqual(c.windowAttentionForTesting, .idle)
    }

    func test_dismissingAFloatsCard_answersTheFloat() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let surface = try floatSurface()
        c.handle(.toggleToolFloat("btop"))
        notify(surface, "needs input")
        XCTAssertEqual(c.windowAttentionForTesting, .waiting)

        c.handle(.dismissToast)
        drainMainQueue()

        XCTAssertEqual(
            c.windowAttentionForTesting, .idle,
            "Dismiss is an answer: the float must stop asking, not just lose its card")
    }

    func test_aFloatsCard_switchesToTheFloat() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let surface = try floatSurface()
        c.handle(.toggleToolFloat("btop"))
        notify(surface, "needs input")
        let card = try XCTUnwrap(toastViews(c).first)
        let switchButton = try XCTUnwrap(
            descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title == "Switch" })

        switchButton.performClick(nil)
        drainMainQueue()

        XCTAssertEqual(c.floatsForTesting.activeID, "btop", "Switch on a float's card opens the float")
        XCTAssertEqual(c.windowAttentionForTesting, .idle)
        XCTAssertTrue(toastViews(c).isEmpty, "the card goes once you are looking at the float")
    }

    func test_openingAFloatByItsOwnChord_takesItsCardDown() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let surface = try floatSurface()
        c.handle(.toggleToolFloat("btop"))
        notify(surface, "needs input")
        XCTAssertEqual(toastViews(c).count, 1)

        c.handle(.toggleToolFloat("btop"))
        drainMainQueue()

        XCTAssertTrue(toastViews(c).isEmpty, "the float answered is the card answered, whichever way you got there")
    }

    func test_aHiddenFloatAsking_dotsItsButton() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let surface = try floatSurface()
        c.handle(.toggleToolFloat("btop"))

        notify(surface, "needs input")

        XCTAssertEqual(c.dockForTesting.dottedToolFloatIDsForTesting, ["btop"])
    }

    func test_aWindowScopedFloat_marksNoSingleTab() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let surface = try floatSurface()
        c.handle(.toggleToolFloat("btop"))

        notify(surface, "needs input")

        XCTAssertNil(
            c.attentionStateForTesting(tabIndex: 0),
            "a window float belongs to no tab, so no tab number claims it")
    }
}
