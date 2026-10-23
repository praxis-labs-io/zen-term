import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

private final class ChordClaimingOverlay: NSView, ModalOverlay {
    var claimedActions: Set<KeyInterceptor.ReservedChord> = []
    var ownedChords: Set<Chord> = []
    private(set) var offered: [KeyInterceptor.ReservedChord] = []

    func focusInitialResponder() {}
    func animateIn() {}
    func animateOut(completion: @escaping () -> Void) { completion() }

    func handle(_ chord: KeyInterceptor.ReservedChord) -> Bool {
        offered.append(chord)
        return claimedActions.contains(chord)
    }

    func owns(_ chord: Chord) -> Bool { ownedChords.contains(chord) }
}

@MainActor
final class ModalChordTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        controller = c
        return c
    }

    private func present(_ overlay: ChordClaimingOverlay, in c: WindowController) {
        c.presentModalForTesting(overlay)
        XCTAssertTrue(c.isModalOverlayOpen, "premise: the overlay is up as the modal")
    }

    private func interceptor(for c: WindowController) -> KeyInterceptor {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.passThroughGuard = { chord, _ in c.modalOwns(chord) }
        return keys
    }

    private func commandReturn() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36))
    }

    func test_aTabActionTheModalClaims_reachesItAndOpensNoTab() {
        let c = makeWindow()
        let overlay = ChordClaimingOverlay()
        overlay.claimedActions = [.newTab]
        present(overlay, in: c)
        let tabs = c.tabOrderForTesting

        c.handle(.newTab)

        XCTAssertEqual(overlay.offered, [.newTab])
        XCTAssertEqual(c.tabOrderForTesting, tabs, "the modal took the chord, so the window must not act on it")
        XCTAssertTrue(c.isModalOverlayOpen)
    }

    func test_aTabActionTheModalDeclines_isDroppedAsBefore() {
        let c = makeWindow()
        let overlay = ChordClaimingOverlay()
        present(overlay, in: c)
        let tabs = c.tabOrderForTesting

        c.handle(.newTab)

        XCTAssertEqual(overlay.offered, [.newTab], "the modal is asked first")
        XCTAssertEqual(c.tabOrderForTesting, tabs, "a declined chord stays swallowed under a modal")
        XCTAssertTrue(c.isModalOverlayOpen)
    }

    func test_aFixedKeyTheModalOwns_isHandedBackRatherThanConsumed() throws {
        let c = makeWindow()
        let overlay = ChordClaimingOverlay()
        overlay.ownedChords = [Chord(command: true, key: "⏎")]
        present(overlay, in: c)
        let keys = interceptor(for: c)
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        let event = try commandReturn()
        XCTAssertIdentical(keys.route(event), event, "the modal has to receive the real event")
        XCTAssertEqual(fired, [], "and fill screen must not run behind it")
    }

    func test_aFixedKeyTheModalDoesNotOwn_isStillConsumedAsItsChord() throws {
        let c = makeWindow()
        present(ChordClaimingOverlay(), in: c)
        let keys = interceptor(for: c)
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try commandReturn()))
        XCTAssertEqual(fired, [.fillScreen])
    }
}
