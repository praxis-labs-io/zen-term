import AppKit
import XCTest

@testable import ZenTerm

final class SettingsFocusRowTests: WindowTestCase {
    private var window: NSWindow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { true }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
    }

    private func mount(_ row: SettingsFocusRow) throws -> SettingsFocusRow {
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        return row
    }

    private func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    private func click(_ row: NSView) throws -> NSEvent {
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        return try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private var rows: [(String, SettingsFocusRow)] {
        [
            (
                "WorkspaceRow",
                WorkspaceRow(
                    workspace: Workspace(title: "Repo", path: URL(fileURLWithPath: "/tmp"), tabs: [], env: [:]))
            ),
            ("SSHHostRow", SSHHostRow(host: "devbox", title: "devbox", subtitle: "10.0.0.5", status: .offline)),
            ("ToolFloatRow", ToolFloatRow(float: .scratch)),
        ]
    }

    func test_settingsListRows_hoverAndFocusLikeTheNav() throws {
        let chrome = Theme.current.chrome
        for (name, made) in rows {
            var chosen = 0
            made.onChoose = { chosen += 1 }
            let row = try mount(made)

            row.mouseEntered(with: try crossing(.mouseEntered))
            XCTAssertEqual(row.layer?.backgroundColor, chrome.fill(.hover).cgColor, "\(name) shows no hover")
            row.mouseExited(with: try crossing(.mouseExited))
            XCTAssertEqual(row.layer?.backgroundColor?.alpha, 0, "\(name) keeps its hover")

            row.mouseDown(with: try click(row))
            XCTAssertEqual(chosen, 1, "\(name) does not open on a click")
            XCTAssertTrue(window.firstResponder === row, "\(name) does not take focus on a click")
            XCTAssertEqual(row.layer?.borderColor, chrome.focusRing.cgColor, "\(name) shows no focus ring")
            XCTAssertEqual(row.layer?.backgroundColor?.alpha, 0, "\(name) fills on focus")

            window.makeFirstResponder(nil)
            XCTAssertEqual(row.layer?.borderColor?.alpha, 0, "\(name) keeps its ring")
            row.removeFromSuperview()
        }
    }

    func test_toolFloatRow_showsItsWarningUnderTheRow() throws {
        let row = try XCTUnwrap(try mount(ToolFloatRow(float: .scratch)) as? ToolFloatRow)
        let quiet = row.fittingSize.height

        row.showMessage("⌘G goes to toggle_search.")

        XCTAssertEqual(row.renderedMessageForTesting, "⌘G goes to toggle_search.")
        XCTAssertGreaterThan(row.fittingSize.height, quiet, "the warning line takes no room under the row")

        row.showMessage(nil)
        XCTAssertNil(row.renderedMessageForTesting)
        XCTAssertEqual(row.fittingSize.height, quiet)
    }
}
