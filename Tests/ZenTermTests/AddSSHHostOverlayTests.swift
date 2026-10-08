import AppKit
import XCTest

@testable import ZenTerm

final class AddSSHHostOverlayTests: WindowTestCase {
    private var window: NSWindow?
    private var submitted: [SSHHostEntry] = []
    private var cancelled = 0
    private var submitFailure: String?
    private var removed = 0
    private var removalFailure: String?
    private var removalConsequence: String?

    override func tearDownWithError() throws {
        window = nil
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mount(
        _ mode: AddSSHHostOverlay.Mode = .add(taken: []), removable: Bool = false
    ) -> AddSSHHostOverlay {
        let overlay = AddSSHHostOverlay(
            mode: mode, background: Theme.current.chrome.background.nsColor,
            removal: removable
                ? AddSSHHostOverlay.Removal(
                    consequence: { [weak self] in self?.removalConsequence },
                    perform: { [weak self] in
                        self?.removed += 1
                        return self?.removalFailure
                    }) : nil,
            onSubmit: { [weak self] in
                self?.submitted.append($0)
                return self?.submitFailure
            },
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
        let overlay = mount(.add(taken: ["devbox"]))
        field(in: overlay).setText("devbox")
        nameField(in: overlay).setText("Build box")

        pressReturn(in: nameField(in: overlay))

        XCTAssertEqual(visibleMessage(in: overlay), "Already added.")
        XCTAssertIdentical(window?.firstResponder, field(in: overlay).field.currentEditor())
        XCTAssertEqual(submitted, [])
    }

    private func button(_ title: String, in overlay: NSView) -> AppButton? {
        descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    private func header(in overlay: NSView) -> String? {
        descendants(of: overlay).compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 15 }?.stringValue
    }

    func test_editing_showsTheHostFixed_andFocusesItsName() throws {
        let overlay = mount(.edit(SSHHostEntry(alias: "devbox", name: "Build box"), address: "drew@10.0.1.12"))

        XCTAssertEqual(header(in: overlay), "Edit SSH Host")
        XCTAssertNotNil(button("Save", in: overlay))
        XCTAssertNil(button("Add", in: overlay))
        XCTAssertEqual(field(in: overlay).field.stringValue, "devbox  drew@10.0.1.12")
        XCTAssertFalse(field(in: overlay).field.isEditable)
        XCTAssertFalse(field(in: overlay).field.acceptsFirstResponder)
        XCTAssertEqual(nameField(in: overlay).text, "Build box")
        XCTAssertIdentical(window?.firstResponder, nameField(in: overlay).field.currentEditor())
        XCTAssertEqual(header(in: mount()), "Add SSH Host")
    }

    func test_editing_saveSubmitsTheAliasWithTheNewName_andAnEmptyNameClearsIt() throws {
        let overlay = mount(.edit(SSHHostEntry(alias: "devbox", name: "Build box"), address: nil))
        nameField(in: overlay).setText("  Builder ")
        let save = try XCTUnwrap(button("Save", in: overlay))
        window?.makeFirstResponder(save)

        save.keyDown(with: returnKey())
        nameField(in: overlay).setText("   ")
        pressReturn(in: nameField(in: overlay))

        XCTAssertEqual(
            submitted, [SSHHostEntry(alias: "devbox", name: "Builder"), SSHHostEntry(alias: "devbox", name: nil)])
    }

    func test_editing_refusesANameWithAQuote() {
        let overlay = mount(.edit(SSHHostEntry(alias: "devbox"), address: nil))
        nameField(in: overlay).setText("The \"box\"")

        pressReturn(in: nameField(in: overlay))

        XCTAssertEqual(visibleMessage(in: overlay), "Can't contain \".")
        XCTAssertEqual(submitted, [])
    }

    private func returnKey() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }

    func test_aFailedSave_showsAFormLevelMessage_thatWraps_andFocusesTheName() throws {
        submitFailure = "Couldn't save devbox to ZenTerm's config: the file is on a volume that is read-only right now"
        let overlay = mount(.edit(SSHHostEntry(alias: "devbox"), address: nil))
        nameField(in: overlay).setText("Build")

        pressReturn(in: nameField(in: overlay))

        let label = try XCTUnwrap(
            descendants(of: overlay).compactMap { $0 as? NSTextField }.first { $0.stringValue == submitFailure })
        overlay.layoutSubtreeIfNeeded()
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(label.textColor, Theme.current.chrome.destructive.nsColor)
        XCTAssertGreaterThan(label.frame.height, label.font.map { $0.boundingRectForFont.height * 1.5 } ?? 0, "wraps")
        let destructive = descendants(of: overlay).compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden && $0.textColor == Theme.current.chrome.destructive.nsColor }
        XCTAssertEqual(destructive, [label], "no field carries it as a validation message")
        XCTAssertIdentical(window?.firstResponder, nameField(in: overlay).field.currentEditor())

        nameField(in: overlay).onChange?()
        XCTAssertTrue(label.isHidden, "typing clears it")
    }

    private let devbox = AddSSHHostOverlay.Mode.edit(SSHHostEntry(alias: "devbox", name: "Build box"), address: nil)

    private func isFocused(_ view: NSView?) -> Bool { view.map { KeyboardFocus.isFocused($0, in: window) } ?? false }

    func test_editing_offersRemove_andAddingDoesNot() {
        XCTAssertNotNil(button("Remove", in: mount(devbox, removable: true)))
        XCTAssertNil(button("Remove", in: mount()))
        XCTAssertNil(button("Remove", in: mount(devbox)))
    }

    func test_remove_leadsTheFooter() throws {
        let overlay = mount(devbox, removable: true)
        let remove = try XCTUnwrap(button("Remove", in: overlay))
        let cancel = try XCTUnwrap(button("Cancel", in: overlay))
        overlay.layoutSubtreeIfNeeded()

        XCTAssertLessThan(remove.frame.minX, cancel.frame.minX)
    }

    func test_remove_withNothingToWarnAbout_removesAtOnce() throws {
        let overlay = mount(devbox, removable: true)

        try XCTUnwrap(button("Remove", in: overlay)).onTap()

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(descendants(of: overlay).contains { $0 is ConfirmCard })
    }

    func test_remove_ofAnOpenHost_asksFirst_andOnlyConfirmingRemoves() throws {
        removalConsequence = "disconnect it and stop everything running in it"
        let overlay = mount(devbox, removable: true)
        try XCTUnwrap(button("Remove", in: overlay)).onTap()

        let card = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? ConfirmCard }.first)
        let texts = descendants(of: card).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(texts.contains("Remove Build box"))
        XCTAssertTrue(
            texts.contains("Removing Build box will disconnect it and stop everything running in it."), "\(texts)")
        XCTAssertEqual(removed, 0)

        try XCTUnwrap(button("Remove", in: card)).onTap()

        XCTAssertEqual(removed, 1)
    }

    func test_cancellingTheWarning_removesNothing_andFocusReturnsToRemove() throws {
        removalConsequence = "stop connecting to it and close its tabs"
        let overlay = mount(devbox, removable: true)
        try XCTUnwrap(button("Remove", in: overlay)).onTap()
        let card = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? ConfirmCard }.first)

        try XCTUnwrap(button("Cancel", in: card)).onTap()

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(isFocused(button("Remove", in: overlay)))
    }

    func test_aFailedConfirmedRemove_canBeRetriedWhileTheCardLeaves() throws {
        removalConsequence = "disconnect it and stop everything running in it"
        removalFailure = "Couldn't remove devbox from ZenTerm's config: the file is read-only right now"
        let overlay = mount(devbox, removable: true)
        let remove = try XCTUnwrap(button("Remove", in: overlay))
        remove.onTap()
        let first = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? ConfirmCard }.first)

        try XCTUnwrap(button("Remove", in: first)).onTap()
        XCTAssertEqual(visibleMessage(in: overlay), removalFailure)
        XCTAssertTrue(isFocused(remove))
        remove.onTap()

        let second = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? ConfirmCard }.first)
        XCTAssertNotIdentical(second, first, "a new warning opens even while the old one is leaving")
    }

    func test_aFailedRemove_showsInTheForm_andFocusReturnsToRemove() throws {
        removalFailure = "Couldn't remove devbox from ZenTerm's config: the file is read-only right now"
        let overlay = mount(devbox, removable: true)

        try XCTUnwrap(button("Remove", in: overlay)).onTap()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(visibleMessage(in: overlay), removalFailure)
        XCTAssertTrue(isFocused(button("Remove", in: overlay)))
        nameField(in: overlay).onChange?()
        XCTAssertNil(visibleMessage(in: overlay), "typing clears it")
    }

    func test_footer_tabWalksNameCancelSaveRemove_andBacktabReverses() throws {
        let overlay = mount(devbox, removable: true)
        let cancel = try XCTUnwrap(button("Cancel", in: overlay))
        let save = try XCTUnwrap(button("Save", in: overlay))
        let remove = try XCTUnwrap(button("Remove", in: overlay))

        nameField(in: overlay).onTab?()
        XCTAssertTrue(isFocused(cancel))
        cancel.onTab?()
        XCTAssertTrue(isFocused(save))
        save.onTab?()
        XCTAssertTrue(isFocused(remove))
        remove.onTab?()
        XCTAssertIdentical(window?.firstResponder, nameField(in: overlay).field.currentEditor())
        nameField(in: overlay).onBacktab?()
        XCTAssertTrue(isFocused(remove))
        remove.onBacktab?()
        XCTAssertTrue(isFocused(save))
    }

    func test_arrows_walkBetweenRemoveAndCancel() throws {
        let overlay = mount(devbox, removable: true)
        let cancel = try XCTUnwrap(button("Cancel", in: overlay))
        let remove = try XCTUnwrap(button("Remove", in: overlay))

        remove.onArrowRight?()
        XCTAssertTrue(isFocused(cancel))
        cancel.onArrowLeft?()
        XCTAssertTrue(isFocused(remove))
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
