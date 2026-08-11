import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The update card morphs through its states (available → downloading → ready) by
/// re-rendering into its host window's toast stack. A re-render must reach the card even when the
/// key window is momentarily foreign (an open save/open panel makes `keyController()` nil) — else the
/// card freezes on a stale state whose `fireOnce` reply is already spent, and Later / Relaunch go
/// dead with no way to dismiss but restart. These drive `UpdateController` through a real window.
@MainActor
final class UpdateControllerHostingTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDown() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        super.tearDown()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func cardTitles(in wc: WindowController) -> [String] {
        guard let root = wc.window.contentView else { return [] }
        return descendants(of: root)
            .compactMap { $0 as? UpdateCardView }
            .flatMap { descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } }
    }

    func test_readyMorphsInPlace_whenKeyWindowIsForeign() {
        let wc = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        controller = wc

        // The key window resolves to our controller for the initial present, then goes foreign
        // (nil) — an open save/open panel or another app frontmost — for the ready morph.
        var keyWindowIsOurs = true
        let update = UpdateController(keyController: { keyWindowIsOurs ? wc : nil })

        update.present(
            state: .available(version: "9.9.9", current: "You're on 1.0.0", notes: [], notesURL: nil),
            actions: .init())
        XCTAssertTrue(
            cardTitles(in: wc).contains { $0.contains("9.9.9 is available") },
            "the available card should be showing: \(cardTitles(in: wc))")

        keyWindowIsOurs = false  // a foreign window is now key — keyController() returns nil
        update.present(state: .ready(version: "9.9.9"), actions: .init())

        // The regression: the card must morph to Ready even though keyController() is nil, so the
        // live Relaunch/Later actions replace the spent ones. A dropped morph leaves it on
        // "available" with dead buttons — the frozen, undismissable card.
        let titles = cardTitles(in: wc)
        XCTAssertTrue(titles.contains { $0.contains("Ready to install") }, "\(titles)")
        XCTAssertFalse(titles.contains { $0.contains("is available") }, "stale card not replaced: \(titles)")
    }

    /// A build run from source has no feed URL, so `AppDelegate` never constructs an
    /// `UpdateController` and Check for Updates used to do nothing at all: no card, no toast, no
    /// on-screen trace. Inert is fine; silent is not, because a dead-looking command reads as
    /// broken. The copy is measured rather than eyeballed for the same reason every toast message
    /// is: it wraps at a fixed column, so a mid-phrase break is invisible until you see it.
    func test_inertNotice_fitsTheToastWrapColumn() {
        for line in UpdateController.inertNotice.message.split(separator: "\n") {
            let width = (String(line) as NSString)
                .size(withAttributes: [.font: ToastView.messageFont]).width
            XCTAssertLessThanOrEqual(
                width, ToastView.messageMaxWidth,
                "wraps at \(Int(width))pt > \(Int(ToastView.messageMaxWidth))pt: \(line)")
        }
    }
}
