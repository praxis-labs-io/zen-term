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
    private var headerConstraints: [NSLayoutConstraint] = []
    private var contentTopToHeader: NSLayoutConstraint?
    private let contentTopToContainer: NSLayoutConstraint

    private var findBar: FindBarView?
    private var findBarConstraints: [NSLayoutConstraint] = []
    private var contentBottomToFindBar: NSLayoutConstraint?
    private let contentBottomToContainer: NSLayoutConstraint

    private static let stripInset: CGFloat = 8

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
            findBar?.isHidden = true
            NSLayoutConstraint.deactivate(findBarConstraints + [contentBottomToFindBar].compactMap { $0 })
            contentBottomToContainer.isActive = true
            return nil
        }
        let bar = findBar ?? makeFindBar()
        bar.isHidden = false
        contentBottomToContainer.isActive = false
        NSLayoutConstraint.activate(findBarConstraints + [contentBottomToFindBar].compactMap { $0 })
        return bar
    }

    var findBarFill: NSColor = .clear {
        didSet { findBar?.paneFill = findBarFill }
    }

    func reapplyTheme() {
        header?.reapplyTheme()
        findBar?.reapplyTheme()
    }

    var scrollCursorForTesting: ScrollCursorView { cursor }
    var findBarForTesting: FindBarView? { findBar?.isHidden == false ? findBar : nil }
    var isHeaderVisibleForTesting: Bool { header.map { !$0.isHidden } ?? false }
    var headerContentForTesting: (title: String, shortcut: String)? { header?.contentForTesting }
    var builtHeaderKeycapForTesting: String? { header?.builtKeycapShortcutForTesting }

    private func setHeaderShown(_ shown: Bool) {
        guard let header, let contentTopToHeader else { return }
        defer { onStripsChanged() }
        header.isHidden = !shown
        if shown {
            contentTopToContainer.isActive = false
            NSLayoutConstraint.activate(headerConstraints + [contentTopToHeader])
        } else {
            NSLayoutConstraint.deactivate(headerConstraints + [contentTopToHeader])
            contentTopToContainer.isActive = true
        }
    }

    @discardableResult
    private func makeHeader(_ meta: PanelMeta) -> PanelHeader {
        let view = PanelHeader(meta)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        container.addSubview(view)
        headerConstraints = [
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.stripInset),
        ]
        contentTopToHeader = content.topAnchor.constraint(
            equalTo: view.bottomAnchor, constant: padding)
        header = view
        return view
    }

    private func makeFindBar() -> FindBarView {
        let bar = FindBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        findBarConstraints = [
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.stripInset),
        ]
        contentBottomToFindBar = content.bottomAnchor.constraint(
            equalTo: bar.topAnchor, constant: -padding)
        findBar = bar
        bar.paneFill = findBarFill
        return bar
    }
}

private final class PanelHeader: NSView {
    private var title: String
    private var action: KeyInterceptor.ReservedChord
    private let titleField = NSTextField(labelWithString: "")
    private var keycap: KeycapView
    private static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)

    var contentForTesting: (title: String, shortcut: String) {
        (titleField.stringValue, CommandCatalog.spec(for: action).shortcut)
    }

    var builtKeycapShortcutForTesting: String { keycap.shortcut }

    init(_ meta: PanelMeta) {
        title = meta.title
        action = meta.action
        keycap = KeycapView(shortcut: CommandCatalog.spec(for: meta.action).shortcut, showsBackground: false)
        super.init(frame: .zero)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        addSubview(keycap)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
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

    func reapplyTheme() {
        applyTitle()
        rebuildKeycap()
    }

    private func rebuildKeycap() {
        keycap.removeFromSuperview()
        keycap = KeycapView(shortcut: CommandCatalog.spec(for: action).shortcut, showsBackground: false)
        addSubview(keycap)
        activateKeycapConstraints()
    }

    private func activateKeycapConstraints() {
        keycap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            keycap.trailingAnchor.constraint(equalTo: trailingAnchor),
            keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            keycap.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 8),
        ])
    }

    private func applyTitle() {
        titleField.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: Self.font,
                .foregroundColor: Theme.current.chrome.ink(.muted),
                .kern: 1.2,
            ])
    }
}
