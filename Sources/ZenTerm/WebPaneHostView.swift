import AppKit
import WebPaneKit

/// The chrome host for a web leaf. Unlike `PanelHostView`, the pane itself is
/// transparent — no fill, no border, no iris halo. Instead a bordered toolbar bar sits
/// on top and IS the focus target: its border goes accent when the pane is focused.
/// The toolbar (back / forward / reload · address · device switch) is built from the
/// shared `IconButton` on `Theme` tokens and drives the surface's control API; the
/// web content renders below it at the selected device width, letterboxed.
final class WebPaneHostView: NSView, PaneHost {
    private let surface: WebPaneSurface
    private let onFocusRequest: () -> Void

    private let toolbar = NSView()
    private let backButton: IconButton
    private let forwardButton: IconButton
    private let reloadButton: IconButton
    private let urlField = NSTextField()
    private let zoomButton: IconButton
    private var deviceButtons: [(preset: DevicePreset, button: IconButton)] = []

    private let outerInset: CGFloat = 8
    private let toolbarHeight: CGFloat = 34

    var isFocused: Bool = false { didSet { if oldValue != isFocused { updateFocus() } } }
    var onZoomExit: (() -> Void)?
    var isZoomed: Bool = false { didSet { zoomButton.isHidden = !isZoomed } }

    init(surface: WebPaneSurface, onFocusRequest: @escaping () -> Void) {
        self.surface = surface
        self.onFocusRequest = onFocusRequest
        self.backButton = IconButton(
            symbol: "chevron.left", accessibilityLabel: "Back", onClick: {})
        self.forwardButton = IconButton(
            symbol: "chevron.right", accessibilityLabel: "Forward", onClick: {})
        self.reloadButton = IconButton(
            symbol: "arrow.clockwise", accessibilityLabel: "Reload", onClick: {})
        self.zoomButton = IconButton(
            symbol: "arrow.down.right.and.arrow.up.left", accessibilityLabel: "Exit zoom", onClick: {})
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        buildToolbar()
        buildContent()
        wire()
        refresh()
        updateFocus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest()
        super.mouseDown(with: event)
    }

    // MARK: build

    private func buildToolbar() {
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 8
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)

        let navStack = NSStackView(views: [backButton, forwardButton, reloadButton])
        navStack.orientation = .horizontal
        navStack.spacing = 2

        urlField.target = self
        urlField.action = #selector(urlSubmitted)
        urlField.placeholderString = "Open URL…"
        urlField.font = .systemFont(ofSize: 11)
        urlField.textColor = Theme.current.chrome.foreground.nsColor
        urlField.isBezeled = false
        urlField.isBordered = false
        urlField.drawsBackground = false
        urlField.focusRingType = .none
        urlField.lineBreakMode = .byTruncatingTail
        urlField.translatesAutoresizingMaskIntoConstraints = false

        // The address field's pill matches the IconButton hover fill so the toolbar reads
        // as one system.
        let fieldWrap = NSView()
        fieldWrap.wantsLayer = true
        fieldWrap.layer?.cornerRadius = 6
        fieldWrap.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.10).cgColor
        fieldWrap.translatesAutoresizingMaskIntoConstraints = false
        fieldWrap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fieldWrap.addSubview(urlField)
        NSLayoutConstraint.activate([
            fieldWrap.heightAnchor.constraint(equalToConstant: 24),
            urlField.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: 8),
            urlField.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -8),
            urlField.centerYAnchor.constraint(equalTo: fieldWrap.centerYAnchor),
        ])

        zoomButton.isHidden = true
        let deviceStack = NSStackView(
            views: DevicePreset.allCases.map { preset in
                let button = IconButton(
                    symbol: preset.symbol, accessibilityLabel: preset.label,
                    onClick: { [weak self] in self?.selectDevice(preset) })
                deviceButtons.append((preset, button))
                return button
            })
        deviceStack.orientation = .horizontal
        deviceStack.spacing = 2

        let row = NSStackView(views: [navStack, fieldWrap, deviceStack, zoomButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(row)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: outerInset),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: outerInset),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -outerInset),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),
            row.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])
    }

    private func buildContent() {
        let content = surface.view
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: outerInset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: outerInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -outerInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -outerInset),
        ])
    }

    private func wire() {
        backButton.onClick = { [weak self] in self?.surface.goBack() }
        forwardButton.onClick = { [weak self] in self?.surface.goForward() }
        reloadButton.onClick = { [weak self] in self?.surface.reload() }
        zoomButton.onClick = { [weak self] in self?.onZoomExit?() }
        surface.onStateChange = { [weak self] in self?.refresh() }
    }

    // MARK: actions

    @objc private func urlSubmitted() { surface.navigate(to: urlField.stringValue) }

    private func selectDevice(_ preset: DevicePreset) {
        surface.setDevice(preset)
        refresh()
    }

    // MARK: state

    private func refresh() {
        if urlField.currentEditor() == nil { urlField.stringValue = surface.addressText }
        backButton.alphaValue = surface.canGoBack ? 1 : 0.35
        forwardButton.alphaValue = surface.canGoForward ? 1 : 0.35
        for (preset, button) in deviceButtons { button.isActive = (surface.device == preset) }
    }

    private static let idleBorder = Theme.current.chrome.ink(alpha: 0.12)

    private func updateFocus() {
        guard let layer = toolbar.layer else { return }
        Motion.ease(
            layer, keyPath: "borderColor",
            to: (isFocused ? Theme.current.chrome.accent.nsColor : Self.idleBorder).cgColor)
    }
}
