import AppKit
import XCTest

@testable import ZenTerm

final class UpdateCardTests: WindowTestCase {
    func test_notesColumn_wrapsAtTheExposedBudgetWidth() {
        let card = UpdateCardView(
            state: .available(
                version: "0.2.0",
                current: "You're on 0.1.4",
                notes: [String(repeating: "wrap ", count: 40)],
                notesURL: nil),
            actions: .init())
        card.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = window.contentView!
        content.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: content.topAnchor),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        ])
        content.layoutSubtreeIfNeeded()

        let notes = firstTextField(in: card) { $0.hasPrefix("•") }
        let label = try? XCTUnwrap(notes)
        let textWidth = label.map { $0.alignmentRect(forFrame: $0.frame).width } ?? -1
        XCTAssertEqual(
            textWidth, UpdateCardView.notesMaxWidth, accuracy: 0.5,
            "the notes text wraps at \(textWidth)pt but notesMaxWidth is "
                + "\(UpdateCardView.notesMaxWidth)pt — the wrap column and the exposed budget disagree")
    }

    func test_bullets_stripsDashAndAsteriskMarkers() {
        XCTAssertEqual(
            ZenUpdateDriver.bullets(from: "- Faster startup\n* Fixes the reorder bug"),
            ["Faster startup", "Fixes the reorder bug"])
    }

    func test_bullets_dropsBlankLines() {
        XCTAssertEqual(
            ZenUpdateDriver.bullets(from: "- one\n\n  \n- two"),
            ["one", "two"])
    }

    func test_bullets_dropsUnmarkedLinesAndHeaders() {
        XCTAssertEqual(
            ZenUpdateDriver.bullets(from: "## Requirements\nmacOS 14 or later.\n- The real bullet"),
            ["The real bullet"])
    }

    func test_bullets_capsAtSix() {
        let many = (1...10).map { "- item \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ZenUpdateDriver.bullets(from: many).count, 6)
    }

    func test_bullets_nilDescription_isEmpty() {
        XCTAssertEqual(ZenUpdateDriver.bullets(from: nil), [])
    }

    func test_title_usesThemeForeground_notASystemColor() {
        let card = UpdateCardView(
            state: .available(version: "9.9.9", current: "You're on 1.0", notes: [], notesURL: nil),
            actions: .init())
        let title = firstTextField(in: card) { $0.contains("9.9.9") }
        XCTAssertEqual(
            title?.textColor, Theme.current.chrome.foreground.nsColor,
            "the title must use the theme foreground, not a system color")
    }

    func test_fireOnce_repliesOnlyOnce() {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let choose = ZenUpdateDriver.fireOnce { _ in counter.n += 1 }
        choose(.install)
        choose(.skip)
        choose(.dismiss)
        XCTAssertEqual(counter.n, 1)
    }

    func test_installButton_firesItsActionWhenClicked() {
        final class Flag: @unchecked Sendable { var tapped = false }
        let flag = Flag()
        var actions = UpdateCardView.Actions()
        actions.install = { flag.tapped = true }
        let card = UpdateCardView(
            state: .available(version: "9.9.9", current: "You're on 1.0", notes: [], notesURL: nil),
            actions: actions)
        card.translatesAutoresizingMaskIntoConstraints = false
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView!.addSubview(card)

        let install = firstButton(in: card) { $0 == "Install" }
        XCTAssertNotNil(install, "the available card must show an Install button")
        install?.performClick(nil)

        XCTAssertTrue(flag.tapped, "clicking Install must fire its wired action end to end")
    }

    private func firstButton(in view: NSView, where match: (String) -> Bool) -> AppButton? {
        for sub in view.subviews {
            if let button = sub as? AppButton, match(button.title) { return button }
            if let found = firstButton(in: sub, where: match) { return found }
        }
        return nil
    }

    private func firstTextField(in view: NSView, where match: (String) -> Bool) -> NSTextField? {
        for sub in view.subviews {
            if let field = sub as? NSTextField, match(field.stringValue) { return field }
            if let found = firstTextField(in: sub, where: match) { return found }
        }
        return nil
    }
}
