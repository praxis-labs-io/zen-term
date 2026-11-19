import AppKit
import XCTest

@testable import ZenTerm

final class ChromeTextViewEscapeTests: WindowTestCase {
    // In full screen AppKit exits full screen instead of forwarding cancelOperation, so reaching here is the bug.
    private final class FullScreenStandInWindow: NSWindow {
        private let editor = ChromeTextView.makeFieldEditor()
        var cancelReachedWindow = false

        override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
            object is NSTextField ? editor : super.fieldEditor(createFlag, for: object)
        }

        override func cancelOperation(_ sender: Any?) { cancelReachedWindow = true }
    }

    private final class ClaimsEscape: NSObject, NSTextFieldDelegate {
        var claimed = 0

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            claimed += 1
            return true
        }
    }

    private var window: FullScreenStandInWindow?

    override func setUp() {
        super.setUp()
        Motion.isReduceMotionEnabled = { true }
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    func test_escInTheWorkspacePickerSearch_closesThePicker_withoutReachingTheWindow() throws {
        var dismissed = 0
        let picker = RepoPickerOverlay(
            entries: [], onChoose: { _, _ in }, onAddWorkspace: {}, onNewWorkspace: { _ in },
            onDismiss: { dismissed += 1 })
        let window = mount(picker)
        picker.focusInitialResponder()
        XCTAssertTrue(window.firstResponder is ChromeTextView, "the search field is being edited")

        try pressEscape(in: window)

        XCTAssertEqual(dismissed, 1)
        XCTAssertFalse(window.cancelReachedWindow)
    }

    func test_escClaimedByTheFieldsDelegate_leavesTheCardOpen() throws {
        var cancelled = 0
        let shell = ModalShell(width: 300, onCancel: { cancelled += 1 })
        let field = NSTextField()
        let delegate = ClaimsEscape()
        field.delegate = delegate
        shell.embed(field)
        let window = mount(shell)
        XCTAssertTrue(window.makeFirstResponder(field))

        try pressEscape(in: window)

        XCTAssertEqual(delegate.claimed, 1)
        XCTAssertEqual(cancelled, 0)
        XCTAssertFalse(window.cancelReachedWindow)
    }

    private func mount(_ overlay: NSView) -> FullScreenStandInWindow {
        let window = FullScreenStandInWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.translatesAutoresizingMaskIntoConstraints = true
        overlay.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(overlay)
        self.window = window
        return window
    }

    private func pressEscape(in window: NSWindow) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.postEvent(event, atStart: true)
        _ = NSApp.nextEvent(matching: .keyDown, until: nil, inMode: .default, dequeue: true)
        XCTAssertEqual(try XCTUnwrap(NSApp.currentEvent).keyCode, 53, "the Esc is the current event")
        window.sendEvent(event)
    }
}
