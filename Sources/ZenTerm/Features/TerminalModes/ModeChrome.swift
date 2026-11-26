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
    private var slideRuns: [ObjectIdentifier: Int] = [:]

    private static let stripInset: CGFloat = ChromeMetrics.Spacing.s8

    // Below required: a pane too narrow for the count and steppers lets the field past the text, not break layout.
    private static let findFieldLimitPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultHigh.rawValue + 1)

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
        setHeaderShown(Self.showsHeader(header))
    }

    func applyHeaderShown() {
        let shown = Self.showsHeader(header)
        guard shown != isHeaderShown else { return }
        setHeaderShown(shown)
        onStripsChanged()
    }

    private static func showsHeader(_ header: PaneHeader?) -> Bool {
        header != nil && GeneralConfig.current.paneHeaders
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
        _ state: ScrollCursorView.State?, metrics: @escaping () -> TerminalCellMetrics?
    ) {
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
            slide(findField, appearing: false)
            return nil
        }
        let field = findField ?? makeFindField()
        guard !isFindFieldShown else { return field }
        isFindFieldShown = true
        field.isDismissed = false
        slide(field, appearing: true)
        return field
    }

    var scrollCursorForTesting: ScrollCursorView { cursor }
    var findFieldForTesting: FindField? { isFindFieldShown ? findField : nil }
    var shownHeaderForTesting: PaneHeader? { isHeaderShown ? header : nil }

    // Core Animation completes a run the moment the next replaces it, so only the latest run may hide the strip.
    private func slide(_ strip: NSView, appearing: Bool) {
        let key = ObjectIdentifier(strip)
        let run = (slideRuns[key] ?? 0) + 1
        slideRuns[key] = run
        let depth = strip.fittingSize.height + Self.stripInset
        strip.isHidden = false
        Motion.slideFade(strip, appearing: appearing, from: CGVector(dx: 0, dy: depth)) {
            [weak self] in
            guard !appearing, self?.slideRuns[key] == run else { return }
            strip.isHidden = true
        }
    }

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

    private func makeFindField() -> FindField {
        let field = FindField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isHidden = true
        container.addSubview(field)
        let pastText = field.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor)
        pastText.priority = Self.findFieldLimitPriority
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pastText,
        ])
        findField = field
        return field
    }
}
