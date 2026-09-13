import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

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

        var keyWindowIsOurs = true
        let update = UpdateController(keyController: { keyWindowIsOurs ? wc : nil })

        update.present(
            state: .available(version: "9.9.9", current: "You're on 1.0.0", notes: [], notesURL: nil),
            actions: .init())
        XCTAssertTrue(
            cardTitles(in: wc).contains { $0.contains("9.9.9 is available") },
            "the available card should be showing: \(cardTitles(in: wc))")

        keyWindowIsOurs = false
        update.present(state: .ready(version: "9.9.9"), actions: .init())

        let titles = cardTitles(in: wc)
        XCTAssertTrue(titles.contains { $0.contains("Ready to install") }, "\(titles)")
        XCTAssertFalse(titles.contains { $0.contains("is available") }, "stale card not replaced: \(titles)")
    }

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
