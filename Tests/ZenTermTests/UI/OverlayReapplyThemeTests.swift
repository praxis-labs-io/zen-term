import AppKit
import XCTest

@testable import ZenTerm

final class OverlayReapplyThemeTests: WindowTestCase {
    private var originalTheme: AppTheme!
    private var tempRoots: [URL] = []

    override func setUp() {
        super.setUp()
        originalTheme = Theme.current
    }

    override func tearDownWithError() throws {
        Theme.setCurrentForTesting(originalTheme)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    private func makeAlternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-overlay-reapply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        try """
        background = #010101
        foreground = #fefefe
        palette = 1=#ff0000
        palette = 5=#00ff00
        # The accent slot, named from the constant rather than pinned. Last, so it still wins if
        # `themeDefault` ever returns to slot 5.
        palette = \(AccentSlot.themeDefault.ansiIndex)=#00ffff
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
    }

    private func present(_ card: NSView, size: NSSize) -> NSWindow {
        let window = makeWindow()
        card.translatesAutoresizingMaskIntoConstraints = true
        window.contentView?.addSubview(card)
        card.frame = NSRect(origin: .zero, size: size)
        window.displayIfNeeded()
        return window
    }

    private func shadowRadius(of card: NSView) -> CGFloat {
        CGFloat(card.layer?.shadowRadius ?? -1)
    }

    private func assertRestyledAsCard(
        _ card: NSView, tier: FloatShadow.Tier, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            card.layer?.backgroundColor, CardChrome.fill.cgColor, "the fill stayed stale", file: file, line: line)
        XCTAssertEqual(
            card.layer?.borderColor, FloatShadow.edge.cgColor, "the border stayed stale", file: file, line: line)
        XCTAssertEqual(
            shadowRadius(of: card), tier.blur, "the shadow is not the \(tier) tier", file: file, line: line)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func test_reapplyTheme_recolorsPaletteOverlayAndPreservesSearchQuery() throws {
        let overlay = RepoPickerOverlay(
            entries: [],
            onChoose: { _, _ in }, onAddWorkspace: {}, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 560, height: 400)

        guard
            let searchField = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.isEditable })
        else {
            return XCTFail("expected the search field")
        }
        searchField.stringValue = "swap"

        let colorBefore = searchField.textColor
        XCTAssertNotNil(colorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyThemeTree()

        XCTAssertNotEqual(colorBefore, searchField.textColor)
        XCTAssertEqual(searchField.stringValue, "swap")
    }

    func test_reapplyTheme_recolorsPaletteOverlayCardShell() throws {
        let overlay = CommandPaletteOverlay(
            commands: { [] },
            onRun: { _ in }, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 560, height: 400)

        guard let card = overlay.subviews.compactMap({ $0 as? CardView }).first else {
            return XCTFail("expected the card")
        }
        let colorBefore = card.layer?.borderColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyThemeTree()

        XCTAssertNotEqual(colorBefore, card.layer?.borderColor)
    }

    func test_reapplyTheme_recolorsWorkspaceFormOverlayAndPreservesTypedTitle() throws {
        let overlay = WorkspaceFormOverlay(
            existingTitles: [],
            onSubmit: { _ in }, onCancel: {}, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 640)

        guard
            let header = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == "Add Workspace" })
        else {
            return XCTFail("expected the header label")
        }
        guard
            let titleField = descendants(of: overlay).compactMap({ $0 as? FieldBox })
                .first(where: { $0.placeholder == "Named after the folder" })
        else {
            return XCTFail("expected the title field")
        }
        titleField.setText("my-project")

        let headerColorBefore = header.textColor
        let titleColorBefore = titleField.field.textColor
        XCTAssertNotNil(headerColorBefore)
        XCTAssertNotNil(titleColorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyThemeTree()

        XCTAssertNotEqual(headerColorBefore, header.textColor)
        XCTAssertNotEqual(titleColorBefore, titleField.field.textColor)
        XCTAssertEqual(titleField.text, "my-project")
    }

    func test_reapplyTheme_recolorsAddWorkspaceCardShell() throws {
        let overlay = WorkspaceFormOverlay(
            existingTitles: [],
            onSubmit: { _ in }, onCancel: {}, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 640)

        guard let card = overlay.subviews.compactMap({ $0 as? CardView }).first else {
            return XCTFail("expected the card")
        }
        let colorBefore = card.layer?.borderColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyThemeTree()

        XCTAssertNotEqual(colorBefore, card.layer?.borderColor)
    }

    func test_reapplyTheme_recolorsNewWorktreeOverlayAndPreservesTypedBranch() throws {
        let overlay = makeWorktreeCard()
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 480)

        guard
            let header = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == "New Worktree" })
        else {
            return XCTFail("expected the header label")
        }
        guard
            let branchField = descendants(of: overlay).compactMap({ $0 as? FieldBox })
                .first(where: { $0.placeholder == "feature/name" })
        else {
            return XCTFail("expected the branch field")
        }
        guard
            let caption = descendants(of: overlay).compactMap({ $0 as? FieldCaption })
                .first(where: { $0.stringValue.hasPrefix("Copy into") })
        else {
            return XCTFail("expected the copy-into caption")
        }
        branchField.setText("feature/zen-473")

        let headerColorBefore = header.textColor
        XCTAssertNotNil(headerColorBefore)
        let captionBefore = caption.attributedStringValue

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyThemeTree()

        XCTAssertNotEqual(headerColorBefore, header.textColor)
        XCTAssertNotEqual(captionBefore, caption.attributedStringValue)
        XCTAssertEqual(branchField.text, "feature/zen-473", "the typed branch survives the recolor")
    }

    func test_reapplyTheme_recolorsTheSpinnerPixels() throws {
        let overlay = makeWorktreeCard()
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 480)

        guard let spinner = descendants(of: overlay).compactMap({ $0 as? Spinner }).first else {
            return XCTFail("expected the spinner")
        }
        let colorsBefore = (spinner.layer?.sublayers ?? []).compactMap(\.backgroundColor)
        XCTAssertEqual(colorsBefore.count, 6, "a 2 by 3 grid of pixels")

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyThemeTree()

        let colorsAfter = (spinner.layer?.sublayers ?? []).compactMap(\.backgroundColor)
        XCTAssertNotEqual(colorsBefore, colorsAfter)
    }

    func test_reapplyTheme_recolorsTheOpenBranchListAndKeepsTheQuery() throws {
        let field = BranchField()
        let window = makeWindow()
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 20, y: 200, width: 400, height: ChromeMetrics.Height.control)
        field.setBranches(["feature/zen-454"], holders: [:])
        field.box.setText("zen")
        field.box.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field.box.field))
        XCTAssertTrue(field.isListOpen)

        guard
            let row = descendants(of: try XCTUnwrap(window.contentView))
                .compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == "feature/zen-454" })
        else {
            return XCTFail("expected the suggestion row")
        }
        let before = row.textColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        field.reapplyThemeTree()

        guard
            let after = descendants(of: try XCTUnwrap(window.contentView))
                .compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == "feature/zen-454" })
        else {
            return XCTFail("the list came down instead of recoloring")
        }
        XCTAssertNotEqual(before, after.textColor)
        XCTAssertEqual(field.text, "zen", "the query survives the recolor")
        field.closeList()
    }

    private func makeWorktreeCard() -> NewWorktreeOverlay {
        let workspace = Workspace(
            title: "ZenTerm", path: FileManager.default.temporaryDirectory,
            tabs: [], env: [:], carry: ["node_modules"])
        let overlay = NewWorktreeOverlay(
            workspace: workspace,
            options: WorktreeStore.CreateOptions(
                branches: [], defaultBase: "origin/main", currentBranch: "main", holders: [:]),
            onSubmit: { _ in }, onCancel: {}, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        return overlay
    }

    func test_reapplyTheme_recolorsTheFormCardsFooterHairline() throws {
        let overlay = WorkspaceFormOverlay(
            existingTitles: [],
            onSubmit: { _ in }, onCancel: {}, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 640)
        window.contentView?.layoutSubtreeIfNeeded()

        let hairline = try XCTUnwrap(
            descendants(of: overlay).first {
                $0.frame.height == 1 && $0.layer?.backgroundColor != nil
            })
        let before = hairline.layer?.backgroundColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyThemeTree()

        XCTAssertNotEqual(before, hairline.layer?.backgroundColor)
    }

    func test_reapplyTheme_recolorsTheCarryListAndKeepsWhatIsPicked() throws {
        let overlay = WorkspaceFormOverlay(
            existingTitles: [],
            onSubmit: { _ in }, onCancel: {}, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 640)

        let carry = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? CarryPicker }.first)
        carry.settle = 0
        carry.probe = { _, _ in
            IgnoredCatalog(entries: ["node_modules"], resting: ["node_modules"], fileCounts: [:], directories: [])
        }
        carry.setCarried(["node_modules"])
        let landed = expectation(description: "catalog")
        carry.onChanged = { if carry.dropdownForTesting != nil { landed.fulfill() } }
        carry.workspaceFolder = FileManager.default.temporaryDirectory
        wait(for: [landed], timeout: 2)
        carry.onChanged = nil
        let list = try XCTUnwrap(carry.dropdownForTesting)
        let before = list.layer?.borderColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyThemeTree()

        XCTAssertNotEqual(before, list.layer?.borderColor)
        XCTAssertEqual(carry.carried, ["node_modules"], "a recolor never loses what was picked")
        XCTAssertEqual(list.buttonTitleForTesting, "1 chosen")
    }

    func test_reapplyTheme_recolorsEnvRowAndPreservesTypedKey() throws {
        let overlay = WorkspaceFormOverlay(
            existingTitles: [],
            onSubmit: { _ in }, onCancel: {}, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 640)

        guard
            let addVarButton = descendants(of: overlay).compactMap({ $0 as? AppButton })
                .first(where: { $0.attributedTitle.string == "＋ Add variable" })
        else {
            return XCTFail("expected the add-variable button")
        }
        addVarButton.onTap()

        guard
            let keyBox = descendants(of: overlay).compactMap({ $0 as? FieldBox })
                .first(where: { $0.placeholder == "KEY" })
        else {
            return XCTFail("expected the env row's KEY field")
        }
        keyBox.setText("FOO")

        guard
            let equalsLabel = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == "=" })
        else {
            return XCTFail("expected the env row's = label")
        }

        let keyColorBefore = keyBox.field.textColor
        let equalsColorBefore = equalsLabel.textColor
        XCTAssertNotNil(keyColorBefore)
        XCTAssertNotNil(equalsColorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyThemeTree()

        XCTAssertNotEqual(keyColorBefore, keyBox.field.textColor)
        XCTAssertNotEqual(equalsColorBefore, equalsLabel.textColor)
        XCTAssertEqual(keyBox.text, "FOO")
    }

    func test_reapplyTheme_recolorsFieldGroupCaption() throws {
        let overlay = WorkspaceFormOverlay(
            existingTitles: [],
            onSubmit: { _ in }, onCancel: {}, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 640)

        guard
            let caption = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.attributedStringValue.string == "Workspace name ✳" })
        else {
            return XCTFail("expected the Workspace name caption")
        }
        let colorBefore =
            caption.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil)
            as? NSColor
        XCTAssertNotNil(colorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyThemeTree()

        let colorAfter =
            caption.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil)
            as? NSColor
        XCTAssertNotEqual(colorBefore, colorAfter)
    }

    func test_reapplyTheme_recolorsBareGroupCaption() throws {
        let overlay = WorkspaceFormOverlay(
            existingTitles: [],
            onSubmit: { _ in }, onCancel: {}, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 640)

        guard
            let caption = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.attributedStringValue.string == "Environment" })
        else {
            return XCTFail("expected the Environment caption")
        }
        let colorBefore =
            caption.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil)
            as? NSColor
        XCTAssertNotNil(colorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyThemeTree()

        let colorAfter =
            caption.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil)
            as? NSColor
        XCTAssertNotEqual(colorBefore, colorAfter)
    }

    func test_reapplyTheme_recolorsToastView() throws {
        let toast = ToastView(
            content: ToastContent(variant: .destructive, title: "Reload Config", message: "Reloaded."))
        toast.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(toast)
        toast.frame = NSRect(x: 0, y: 0, width: 300, height: 80)

        guard
            let titleLabel = descendants(of: toast).compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == "Reload Config" })
        else {
            return XCTFail("expected the toast's title label")
        }
        let colorBefore = titleLabel.textColor
        let borderBefore = toast.layer?.borderColor
        let badgeBefore = toast.badgeFillForTesting
        let glyphBefore = toast.badgeIconTintForTesting
        XCTAssertNotNil(colorBefore)
        XCTAssertNotNil(badgeBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        toast.reapplyThemeTree()

        XCTAssertNotEqual(colorBefore, titleLabel.textColor)
        XCTAssertNotEqual(borderBefore, toast.layer?.borderColor)
        XCTAssertNotEqual(badgeBefore, toast.badgeFillForTesting, "the badge fill stayed stale")
        XCTAssertNotEqual(glyphBefore, toast.badgeIconTintForTesting, "the badge glyph stayed stale")
        XCTAssertEqual(
            toast.badgeIconTintForTesting, Theme.current.chrome.destructive.nsColor,
            "a destructive toast's badge must carry the destructive role, not the chrome accent")
        window.displayIfNeeded()
        assertRestyledAsCard(toast, tier: .float)
    }

    func test_reapplyTheme_restylesUpdateCard() throws {
        let card = UpdateCardView(
            state: .available(version: "9.9.9", current: "You're on 1.0", notes: [], notesURL: nil),
            actions: .init())
        let window = present(card, size: NSSize(width: UpdateCardView.width, height: 160))
        assertRestyledAsCard(card, tier: .float)
        let fillBefore = card.layer?.backgroundColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        card.reapplyThemeTree()
        window.displayIfNeeded()

        XCTAssertNotEqual(fillBefore, card.layer?.backgroundColor)
        assertRestyledAsCard(card, tier: .float)
        let chrome = Theme.current.chrome
        XCTAssertEqual(
            card.badgeFillForTesting, chrome.tint(chrome.accent, alpha: ChromeTheme.badgeTint).cgColor,
            "the badge fill stayed stale")
        XCTAssertEqual(card.badgeIconTintForTesting, chrome.accent.nsColor, "the badge glyph stayed stale")
    }

    func test_reapplyTheme_recolorsTheRecordBadge() throws {
        let bubble = KeybindHintBubble()
        _ = present(bubble, size: NSSize(width: 220, height: 120))
        let fillBefore = bubble.badgeFillForTesting
        let tintBefore = bubble.badgeIconTintForTesting

        Theme.setCurrentForTesting(try makeAlternateTheme())
        bubble.reapplyThemeTree()

        let chrome = Theme.current.chrome
        XCTAssertNotEqual(fillBefore, bubble.badgeFillForTesting, "the badge fill stayed stale")
        XCTAssertNotEqual(tintBefore, bubble.badgeIconTintForTesting, "the badge glyph stayed stale")
        XCTAssertEqual(bubble.badgeFillForTesting, chrome.tint(chrome.accent, alpha: ChromeTheme.badgeTint).cgColor)
        XCTAssertEqual(bubble.badgeIconTintForTesting, chrome.accent.nsColor)
    }

    func test_reapplyTheme_restylesFontSizeCard() throws {
        let card = FontSizeCard(text: "14")
        let window = present(card, size: NSSize(width: 80, height: 40))
        assertRestyledAsCard(card, tier: .float)
        let fillBefore = card.layer?.backgroundColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        card.reapplyThemeTree()
        window.displayIfNeeded()

        XCTAssertNotEqual(fillBefore, card.layer?.backgroundColor)
        assertRestyledAsCard(card, tier: .float)
    }

    func test_reapplyTheme_recolorsToastActionButtons() throws {
        let toast = ToastView(
            content: ToastContent(variant: .info, title: "shell", message: "Waiting."),
            actions: [
                ToastAction(title: "Dismiss", kind: .cancel) {},
                ToastAction(title: "Switch", kind: .primary) {},
            ])
        toast.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(toast)
        toast.frame = NSRect(x: 0, y: 0, width: 300, height: 110)

        let before = toast.actionTitleColorsForTesting
        XCTAssertEqual(before.count, 2, "expected both action buttons")

        Theme.setCurrentForTesting(try makeAlternateTheme())
        toast.reapplyThemeTree()

        XCTAssertNotEqual(before, toast.actionTitleColorsForTesting, "the action buttons stayed stale")
        XCTAssertTrue(
            toast.actionTitleColorsForTesting.contains(Theme.current.chrome.onAccent.nsColor),
            "the primary action must carry the new onAccent")
    }

    func test_toastBadge_carriesTheVariantTone_notTheChromeAccent() throws {
        let window = makeWindow()
        func badge(_ variant: ToastVariant) -> NSColor? {
            let toast = ToastView(content: ToastContent(variant: variant, title: "T", message: "M"))
            toast.translatesAutoresizingMaskIntoConstraints = true
            window.contentView?.addSubview(toast)
            toast.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
            return toast.badgeIconTintForTesting
        }
        let tones = [ToastVariant.info, .positive, .warning, .destructive].map(badge)
        XCTAssertEqual(
            tones.count, Set(tones.map { $0?.description ?? "nil" }).count,
            "two variants share a badge tone")
        XCTAssertEqual(badge(.warning), Theme.current.chrome.warning.nsColor)
    }

    func test_reapplyTheme_recolorsModalHeaderTitle() throws {
        let header = ModalHeader(title: "Report an Issue")
        let title = try XCTUnwrap(descendants(of: header).compactMap { $0 as? NSTextField }.first)
        let before = title.textColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        header.reapplyThemeTree()

        XCTAssertNotEqual(before, title.textColor, "the title stayed stale")
        XCTAssertEqual(title.textColor, Theme.current.chrome.ink(.normal))
    }
}
