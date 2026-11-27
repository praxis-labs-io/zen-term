import AppKit
import TerminalKit

final class ModeChrome {
    private let container: NSView
    private let content: NSView
    private let padding: CGFloat

    /// Flipping a constraint does not mark the host for layout, and its ring reads the frame at draw time.
    private let onStripsChanged: () -> Void

    private let cursor = ScrollCursorView()

    private let header: PaneHeader?
    private var isHeaderShown = false
    private var contentTopToHeader: NSLayoutConstraint?
    private let contentTopToContainer: NSLayoutConstraint

    private var findField: FindField?
    private var isFindFieldShown = false
    private var fadeRun = 0

    private static let stripInset: CGFloat = ChromeMetrics.Spacing.s8

    static var headerCenterY: CGFloat { stripInset + ChromeMetrics.Height.xs / 2 }

    // What a shown header takes from the content's height, above the padding it would have anyway.
    static var headerRoom: CGFloat {
        GeneralConfig.current.paneHeaders ? stripInset + ChromeMetrics.Height.xs : 0
    }

    init(
        container: NSView, content: NSView, padding: CGFloat, header: PaneHeader?,
        onStripsChanged: @escaping () -> Void
    ) {
        self.header = header
        self.container = container
        self.content = content
        self.padding = padding
        self.onStripsChanged = onStripsChanged
        contentTopToContainer = content.topAnchor.constraint(
            equalTo: container.topAnchor, constant: padding)
        NSLayoutConstraint.activate([
            contentTopToContainer,
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
        ])

        cursor.translatesAutoresizingMaskIntoConstraints = false
        cursor.isHidden = true
        container.addSubview(cursor)
        NSLayoutConstraint.activate([
            cursor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            cursor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            cursor.topAnchor.constraint(equalTo: content.topAnchor),
            cursor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        if let header { mount(header) }
        setHeaderShown(showsHeader)
    }

    func applyHeaderShown() {
        guard showsHeader != isHeaderShown else { return }
        setHeaderShown(showsHeader)
        onStripsChanged()
    }

    /// Find lives in the header, so a pane with headers off shows its header while a search runs.
    private var showsHeader: Bool {
        header != nil && (GeneralConfig.current.paneHeaders || isFindFieldShown)
    }

    private func setHeaderShown(_ shown: Bool) {
        isHeaderShown = shown
        header?.isHidden = !shown
        if shown {
            contentTopToContainer.isActive = false
            contentTopToHeader?.isActive = true
        } else {
            contentTopToHeader?.isActive = false
            contentTopToContainer.isActive = true
        }
    }

    func setScrollCursor(
        _ state: ScrollCursorView.State?, readout: String?, metrics: @escaping () -> TerminalCellMetrics?
    ) {
        header?.isScrolling = state != nil
        header?.scrollReadout = readout
        guard let state else {
            cursor.isHidden = true
            cursor.metrics = nil
            cursor.state = nil
            return
        }
        cursor.metrics = metrics
        cursor.state = state
        cursor.isHidden = false
        cursor.redraw()
    }

    @discardableResult
    func setFindFieldShown(_ shown: Bool) -> FindField? {
        guard shown else {
            guard isFindFieldShown, let findField else { return nil }
            isFindFieldShown = false
            findField.isDismissed = true
            header?.isFinding = false
            if GeneralConfig.current.paneHeaders {
                fade(findField, appearing: false)
            } else {
                findField.isHidden = true
            }
            applyHeaderShown()
            return nil
        }
        guard let field = findField ?? makeFindField() else { return nil }
        guard !isFindFieldShown else { return field }
        isFindFieldShown = true
        field.isDismissed = false
        applyHeaderShown()
        header?.isFinding = true
        fade(field, appearing: true)
        return field
    }

    // Core Animation completes a run the moment the next replaces it, so only the latest run may hide the field.
    private func fade(_ field: FindField, appearing: Bool) {
        fadeRun += 1
        let run = fadeRun
        field.isHidden = false
        field.wantsLayer = true
        if appearing { field.layer?.opacity = 0 }
        Motion.fade(field, to: appearing ? 1 : 0) { [weak self] in
            guard !appearing, self?.fadeRun == run else { return }
            field.isHidden = true
        }
    }

    var scrollCursorForTesting: ScrollCursorView { cursor }
    var findFieldForTesting: FindField? { isFindFieldShown ? findField : nil }
    var shownHeaderForTesting: PaneHeader? { isHeaderShown ? header : nil }

    private func mount(_ view: PaneHeader) {
        view.isHidden = true
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.stripInset),
        ])
        contentTopToHeader = content.topAnchor.constraint(
            equalTo: view.bottomAnchor, constant: padding)
    }

    private func makeFindField() -> FindField? {
        guard let header else { return nil }
        let field = FindField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isHidden = true
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: header.chipTrailingAnchor, constant: ChromeMetrics.Spacing.s8),
            field.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        findField = field
        return field
    }
}
