import AppKit
import TerminalKit

final class ModeChrome {
    private let container: NSView
    private let content: NSView
    private let padding: CGFloat

    /// Flipping a constraint does not mark the host for layout, and its ring reads the frame at draw time.
    private let onStripsChanged: () -> Void

    private let cursor = ScrollCursorView()

    private var header: PanelHeader?
    private var isHeaderShown = false
    private var contentTopToHeader: NSLayoutConstraint?
    private let contentTopToContainer: NSLayoutConstraint

    private var findBar: FindBarView?
    private var isFindBarShown = false
    private var slideRuns: [ObjectIdentifier: Int] = [:]
    private var contentBottomToFindBar: NSLayoutConstraint?
    private let contentBottomToContainer: NSLayoutConstraint

    private static let stripInset: CGFloat = ChromeMetrics.Spacing.s8

    init(
        container: NSView, content: NSView, padding: CGFloat, header: PanelMeta?,
        onStripsChanged: @escaping () -> Void
    ) {
        self.container = container
        self.content = content
        self.padding = padding
        self.onStripsChanged = onStripsChanged
        contentTopToContainer = content.topAnchor.constraint(
            equalTo: container.topAnchor, constant: padding)
        contentBottomToContainer = content.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -padding)
        NSLayoutConstraint.activate([contentTopToContainer, contentBottomToContainer])

        cursor.translatesAutoresizingMaskIntoConstraints = false
        cursor.isHidden = true
        container.addSubview(cursor)
        NSLayoutConstraint.activate([
            cursor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            cursor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            cursor.topAnchor.constraint(equalTo: content.topAnchor),
            cursor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        if let header { makeHeader(header) }
    }

    func setHeader(_ meta: PanelMeta?) {
        guard let meta else {
            if header != nil { setHeaderShown(false) }
            return
        }
        let view = header ?? makeHeader(meta)
        view.apply(meta)
        setHeaderShown(true)
    }

    func reapplyKeymap() { header?.reapplyKeymap() }

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
    func setFindBarShown(_ shown: Bool) -> FindBarView? {
        defer { onStripsChanged() }
        guard shown else {
            guard isFindBarShown, let findBar, let contentBottomToFindBar else { return nil }
            isFindBarShown = false
            contentBottomToFindBar.isActive = false
            contentBottomToContainer.isActive = true
            slide(findBar, appearing: false, fromBottom: true)
            return nil
        }
        let bar = findBar ?? makeFindBar()
        guard !isFindBarShown else { return bar }
        isFindBarShown = true
        contentBottomToContainer.isActive = false
        contentBottomToFindBar?.isActive = true
        slide(bar, appearing: true, fromBottom: true)
        return bar
    }

    var findBarFill: NSColor = .clear {
        didSet { findBar?.paneFill = findBarFill }
    }

    var scrollCursorForTesting: ScrollCursorView { cursor }
    var findBarForTesting: FindBarView? { isFindBarShown ? findBar : nil }
    var isHeaderVisibleForTesting: Bool { isHeaderShown }
    var headerViewForTesting: NSView? { header }
    var headerContentForTesting: (title: String, shortcut: String)? { header?.contentForTesting }
    var builtHeaderKeycapForTesting: String? { header?.builtKeycapShortcutForTesting }

    private func setHeaderShown(_ shown: Bool) {
        guard let header, let contentTopToHeader, shown != isHeaderShown else { return }
        defer { onStripsChanged() }
        isHeaderShown = shown
        if shown {
            contentTopToContainer.isActive = false
            contentTopToHeader.isActive = true
        } else {
            contentTopToHeader.isActive = false
            contentTopToContainer.isActive = true
        }
        slide(header, appearing: shown, fromBottom: false)
    }

    // Core Animation completes a run the moment the next replaces it, so only the latest run may hide the strip.
    private func slide(_ strip: NSView, appearing: Bool, fromBottom: Bool) {
        let key = ObjectIdentifier(strip)
        let run = (slideRuns[key] ?? 0) + 1
        slideRuns[key] = run
        let depth = strip.fittingSize.height + Self.stripInset
        strip.isHidden = false
        Motion.slideFade(strip, appearing: appearing, from: CGVector(dx: 0, dy: fromBottom ? -depth : depth)) {
            [weak self] in
            guard !appearing, self?.slideRuns[key] == run else { return }
            strip.isHidden = true
        }
    }

    @discardableResult
    private func makeHeader(_ meta: PanelMeta) -> PanelHeader {
        let view = PanelHeader(meta)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.stripInset),
        ])
        contentTopToHeader = content.topAnchor.constraint(
            equalTo: view.bottomAnchor, constant: padding)
        header = view
        return view
    }

    private func makeFindBar() -> FindBarView {
        let bar = FindBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.stripInset),
        ])
        contentBottomToFindBar = content.bottomAnchor.constraint(
            equalTo: bar.topAnchor, constant: -padding)
        findBar = bar
        bar.paneFill = findBarFill
        return bar
    }
}

private final class PanelHeader: NSView, ThemeReapplying {
    private var title: String
    private var action: KeyInterceptor.ReservedChord
    private let titleField = NSTextField(labelWithString: "")
    private var keycap: KeycapView
    private static let font = ChromeType.font(.small, weight: .medium, face: .digits)

    var contentForTesting: (title: String, shortcut: String) {
        (titleField.stringValue, CommandCatalog.spec(for: action).shortcut)
    }

    var builtKeycapShortcutForTesting: String { keycap.shortcut }

    init(_ meta: PanelMeta) {
        title = meta.title
        action = meta.action
        keycap = KeycapView(shortcut: CommandCatalog.spec(for: meta.action).shortcut, style: .plain)
        super.init(frame: .zero)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        addSubview(keycap)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.xs),
        ])
        activateKeycapConstraints()
        applyTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ meta: PanelMeta) {
        let actionMoved = action != meta.action
        title = meta.title
        action = meta.action
        applyTitle()
        if actionMoved { rebuildKeycap() }
    }

    func reapplyTheme() { applyTitle() }

    func reapplyKeymap() { rebuildKeycap() }

    private func rebuildKeycap() {
        keycap.removeFromSuperview()
        keycap = KeycapView(shortcut: CommandCatalog.spec(for: action).shortcut, style: .plain)
        addSubview(keycap)
        activateKeycapConstraints()
    }

    private func activateKeycapConstraints() {
        keycap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            keycap.trailingAnchor.constraint(equalTo: trailingAnchor),
            keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            keycap.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleField.trailingAnchor, constant: ChromeMetrics.Spacing.s8),
        ])
    }

    private func applyTitle() {
        titleField.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: Self.font,
                .foregroundColor: Theme.current.chrome.ink(.muted),
            ])
    }
}
