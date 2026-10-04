import AppKit
import XCTest

@testable import ZenTerm

final class AddSSHHostOverlayTests: WindowTestCase {
    private var window: NSWindow?
    private var submitted: [SSHHostEntry] = []
    private var cancelled = 0

    override func tearDownWithError() throws {
        window = nil
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mount(taken: Set<String> = []) -> AddSSHHostOverlay {
        let overlay = AddSSHHostOverlay(
            taken: taken, background: Theme.current.chrome.background.nsColor,
            onSubmit: { [weak self] in self?.submitted.append($0) },
            onCancel: { [weak self] in self?.cancelled += 1 })
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        window = win
        overlay.focusInitialResponder()
        return overlay
    }

    private func field(in overlay: NSView) -> FieldBox {
        descendants(of: overlay).compactMap { $0 as? FieldBox }.first!
    }

    private func nameField(in overlay: NSView) -> FieldBox {
        descendants(of: overlay).compactMap { $0 as? FieldBox }[1]
    }

    private func pressReturn(in box: FieldBox) {
        _ = box.control(box.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    private func visibleMessage(in overlay: NSView) -> String? {
        descendants(of: overlay).compactMap { $0 as? NSTextField }
            .first { !$0.isHidden && $0.textColor == Theme.current.chrome.destructive.nsColor }?.stringValue
    }

    func test_returnOnHost_movesToName_andReturnOnName_submitsTheTrimmedHostWithNoName() {
        let overlay = mount()
        field(in: overlay).setText("  deploy@10.0.0.5 ")

        pressReturn(in: field(in: overlay))
        XCTAssertEqual(submitted, [])
        XCTAssertIdentical(window?.firstResponder, nameField(in: overlay).field.currentEditor())
        pressReturn(in: nameField(in: overlay))

        XCTAssertEqual(submitted, [SSHHostEntry(alias: "deploy@10.0.0.5")])
    }

    func test_aTypedName_isSubmittedTrimmed() {
        let overlay = mount()
        field(in: overlay).setText("deploy@10.0.0.5")
        nameField(in: overlay).setText("  Deploy box ")

        pressReturn(in: nameField(in: overlay))

        XCTAssertEqual(submitted, [SSHHostEntry(alias: "deploy@10.0.0.5", name: "Deploy box")])
    }

    func test_aNameWithAQuote_isRefused() {
        let overlay = mount()
        field(in: overlay).setText("deploy@10.0.0.5")
        nameField(in: overlay).setText("The \"box\"")

        pressReturn(in: nameField(in: overlay))

        XCTAssertEqual(visibleMessage(in: overlay), "Can't contain \".")
        XCTAssertEqual(submitted, [])
    }

    func test_anEmptyHost_staysOpenWithAMessage() {
        let overlay = mount()
        field(in: overlay).setText("   ")

        pressReturn(in: nameField(in: overlay))

        XCTAssertEqual(submitted, [])
        XCTAssertEqual(visibleMessage(in: overlay), "Enter a host.")
    }

    func test_aHostWithASpaceOrComma_isRefused() {
        let overlay = mount()
        for text in ["dev box", "dev,box"] {
            field(in: overlay).setText(text)

            pressReturn(in: nameField(in: overlay))

            XCTAssertEqual(visibleMessage(in: overlay), "Can't contain spaces, commas, # or \".", text)
        }
        XCTAssertEqual(submitted, [])
    }

    func test_aHostStartingWithADash_isRefused() {
        let overlay = mount()
        field(in: overlay).setText("-oProxyCommand=x")

        pressReturn(in: nameField(in: overlay))

        XCTAssertEqual(visibleMessage(in: overlay), "Can't start with -.")
        XCTAssertEqual(submitted, [])
    }

    func test_aHostEndingWithAColon_isRefused_becauseItWouldReadBackWithoutTheColon() {
        let overlay = mount()
        field(in: overlay).setText("devbox:")

        pressReturn(in: nameField(in: overlay))

        XCTAssertEqual(visibleMessage(in: overlay), "Can't end with :.")
        XCTAssertEqual(submitted, [])
        XCTAssertEqual(SSHHostEntry(configValue: "devbox:")?.alias, "devbox")
    }

    func test_aHostAlreadyAdded_isRefused_ratherThanDroppingTheTypedName() {
        let overlay = mount(taken: ["devbox"])
        field(in: overlay).setText("devbox")
        nameField(in: overlay).setText("Build box")

        pressReturn(in: nameField(in: overlay))

        XCTAssertEqual(visibleMessage(in: overlay), "Already added.")
        XCTAssertIdentical(window?.firstResponder, field(in: overlay).field.currentEditor())
        XCTAssertEqual(submitted, [])
    }

    func test_escape_cancels() {
        let overlay = mount()
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!

        _ = overlay.performKeyEquivalent(with: escape)

        XCTAssertEqual(cancelled, 1)
    }
}
