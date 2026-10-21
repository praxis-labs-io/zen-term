import AppKit
import TabKit
import XCTest

@testable import ZenTerm

final class GallerySeamTests: WindowTestCase {
    private struct Rendered: Equatable {
        let path: String
        let type: String
        let isHidden: Bool
        let background: [CGFloat]?
        let borderWidth: CGFloat
        let border: [CGFloat]?
        let looseSublayers: [[CGFloat]?]
        let title: NSAttributedString?
        let tint: [CGFloat]?
        let text: NSAttributedString?
        let textColor: [CGFloat]?
    }

    private var window: NSWindow!
    private var originalConfig = GeneralConfig.builtIn
    private var originalTheme = Theme.builtIn

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalConfig = GeneralConfig.current
        originalTheme = Theme.current
        GeneralConfig.setCurrentForTesting(.builtIn)
        Theme.setCurrentForTesting(Theme.builtIn)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
    }

    override func tearDownWithError() throws {
        TooltipPresenter.shared.dismiss()
        window = nil
        GeneralConfig.setCurrentForTesting(originalConfig)
        Theme.setCurrentForTesting(originalTheme)
        try super.tearDownWithError()
    }

    func test_appButtonFocusSeam_rendersLikeRealFocus() {
        for variant in GalleryButtons.variants {
            let (rest, real, seam) = (button(variant), button(variant), button(variant))
            mount([rest, real, seam])
            XCTAssertTrue(window.makeFirstResponder(real))
            seam.forceFocusForGallery()
            assertSeam(seam, matches: real, unlike: rest, GalleryButtons.title(for: variant))
            window.makeFirstResponder(nil)
        }
    }

    func test_fieldBoxFocusSeam_rendersLikeRealFocus() {
        let (rest, real, seam) = (
            sized(FieldBox(placeholder: "Name")), sized(FieldBox(placeholder: "Name")),
            sized(FieldBox(placeholder: "Name"))
        )
        mount([rest, real, seam])
        XCTAssertTrue(window.makeFirstResponder(real.field))
        seam.forceFocusForGallery()
        assertSeam(seam, matches: real, unlike: rest, "FieldBox")
    }

    func test_textAreaBoxFocusSeam_rendersLikeRealFocus() {
        let (rest, real, seam) = (
            sized(TextAreaBox(placeholder: "Note")), sized(TextAreaBox(placeholder: "Note")),
            sized(TextAreaBox(placeholder: "Note"))
        )
        mount([rest, real, seam])
        XCTAssertTrue(window.makeFirstResponder(real.textView))
        seam.forceFocusForGallery()
        assertSeam(seam, matches: real, unlike: rest, "TextAreaBox")
    }

    func test_dropdownFocusSeam_rendersLikeRealFocus() {
        let (rest, real, seam) = (dropdown(), dropdown(), dropdown())
        mount([rest, real, seam])
        XCTAssertTrue(window.makeFirstResponder(real))
        seam.forceFocusForGallery()
        assertSeam(seam, matches: real, unlike: rest, "Dropdown")
    }

    func test_checkboxDropdownFocusSeam_rendersLikeRealFocus() {
        let (rest, real, seam) = (checkboxDropdown(), checkboxDropdown(), checkboxDropdown())
        mount([rest, real, seam])
        XCTAssertTrue(window.makeFirstResponder(real))
        seam.forceFocusForGallery()
        assertSeam(seam, matches: real, unlike: rest, "CheckboxDropdown")
    }

    func test_segmentedControlFocusSeam_rendersLikeRealFocus() {
        let (rest, real, seam) = (segmented(), segmented(), segmented())
        mount([rest, real, seam])
        XCTAssertTrue(window.makeFirstResponder(real))
        seam.forceFocusForGallery()
        assertSeam(seam, matches: real, unlike: rest, "SegmentedControl")
    }

    func test_workspaceTabChipFocusSeam_rendersLikeRealFocus() {
        let (rest, real, seam) = (chip(), chip(), chip())
        mount([rest, real, seam])
        XCTAssertTrue(window.makeFirstResponder(real))
        seam.forceFocusForGallery()
        assertSeam(seam, matches: real, unlike: rest, "WorkspaceTabChip")
    }

    func test_iconButtonHoverSeam_rendersLikeRealHover_withoutATooltip() {
        let (rest, real, seam) = (iconButton(), iconButton(), iconButton())
        mount([rest, real, seam])
        real.mouseEntered(with: crossing(.mouseEntered))
        seam.forceHoverForGallery()
        assertSeam(seam, matches: real, unlike: rest, "IconButton")

        settle()
        XCTAssertNotNil(TooltipPresenter.shared.tooltipForTesting, "the real hover's tooltip never appeared")
        TooltipPresenter.shared.dismiss()
        seam.forceHoverForGallery()
        settle()
        XCTAssertNil(TooltipPresenter.shared.tooltipForTesting, "the gallery's forced hover popped a real tooltip")
    }

    func test_tabBarHoverSeam_rendersLikeRealHover_andSurvivesARender() throws {
        let (rest, real, seam) = (tabBar(), tabBar(), tabBar())
        mount([rest, real, seam])
        let hovered = try XCTUnwrap(real.chipsForTesting.dropFirst().first)
        hovered.mouseEntered(with: crossing(.mouseEntered))
        seam.forceHoverForGallery(tab: TabID(2))
        assertSeam(seam, matches: real, unlike: rest, "TabBarView")

        let pinned = render(seam)
        seam.render(Self.tabItems)
        real.render(Self.tabItems)
        XCTAssertEqual(render(seam), pinned, "a render cleared the pinned hover")
        XCTAssertNotEqual(render(real), render(seam), "a render no longer clears pointer hover off a key window")
    }

    private func assertSeam(
        _ seam: NSView, matches real: NSView, unlike rest: NSView, _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNotEqual(render(real), render(rest), "\(name): the real path changed nothing", file: file, line: line)
        let drift = zip(render(seam), render(real)).filter { $0 != $1 }.map { "seam \($0)\nreal \($1)" }
        XCTAssertEqual(
            render(seam).count, render(real).count, "\(name): the seam built a different tree", file: file, line: line)
        XCTAssertTrue(
            drift.isEmpty, "\(name): the seam drifted from the real path\n" + drift.joined(separator: "\n"), file: file,
            line: line)
    }

    private func render(_ root: NSView) -> [Rendered] {
        var out: [Rendered] = []
        func walk(_ view: NSView, _ path: String) {
            let layer = view.layer
            let backing = Set(view.subviews.compactMap(\.layer).map(ObjectIdentifier.init))
            let loose = (layer?.sublayers ?? []).filter { !backing.contains(ObjectIdentifier($0)) }.map {
                $0.borderColor?.components
            }
            let button = view as? NSButton
            let field = view as? NSTextField
            out.append(
                Rendered(
                    path: path, type: String(describing: type(of: view)), isHidden: view.isHidden,
                    background: layer?.backgroundColor?.components, borderWidth: layer?.borderWidth ?? 0,
                    border: layer?.borderColor?.components, looseSublayers: loose,
                    title: button?.attributedTitle,
                    tint: (button?.contentTintColor ?? (view as? NSImageView)?.contentTintColor)?.cgColor.components,
                    text: field?.attributedStringValue, textColor: field?.textColor?.cgColor.components))
            guard field == nil else { return }
            for (index, child) in view.subviews.enumerated() { walk(child, "\(path)/\(index)") }
        }
        walk(root, "0")
        return out
    }

    private func mount(_ views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(stack)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func settle() {
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: deadline) }
    }

    private func crossing(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    private func button(_ variant: AppButton.Variant) -> AppButton {
        let button = AppButton(title: "Open", variant: variant)
        button.isKeyboardFocusable = true
        return button
    }

    private func sized<View: NSView>(_ view: View) -> View {
        view.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return view
    }

    private func dropdown() -> Dropdown {
        sized(
            Dropdown(
                items: [DropdownItem(title: "One", group: nil, note: nil, isSelected: true)], selectedIndex: 0
            ) { _ in })
    }

    private func checkboxDropdown() -> CheckboxDropdown {
        sized(CheckboxDropdown(title: "1 shown", items: [CheckboxDropdownItem(title: "One", isChecked: true)]) { _ in })
    }

    private func segmented() -> SegmentedControl {
        SegmentedControl(options: ["Off", "On"]) { _ in }
    }

    private func chip() -> WorkspaceTabChip {
        let chip = WorkspaceTabChip()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.update(title: "api", defaultName: "Workspace", selected: false, opensFocused: false, removable: false)
        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: chip.fittingWidth),
            chip.heightAnchor.constraint(equalToConstant: WorkspaceTabChip.height),
        ])
        return chip
    }

    private func iconButton() -> IconButton {
        IconButton(symbol: "plus", accessibilityLabel: "New tab", onClick: {})
    }

    private static let tabItems = [
        TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, attentionState: .idle),
        TabBarItem(id: TabID(2), index: 2, title: "two", isActive: false, attentionState: .idle),
    ]

    private func tabBar() -> TabBarView {
        let bar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: 400),
            bar.heightAnchor.constraint(equalToConstant: TabBarView.height),
        ])
        bar.render(Self.tabItems)
        return bar
    }
}
