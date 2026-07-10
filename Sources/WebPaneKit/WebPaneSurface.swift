import AppKit
import TerminalKit
import WebKit

/// A `TerminalSurface` backed by a `WKWebView` — a pinned web pane that tiles in the
/// pane tree like any terminal. Carries its own toolbar (back / forward / reload /
/// editable URL field / device switch); the device switch constrains the web view's
/// real width (no zoom) so responsive CSS reflows as it would on the device.
///
/// Spike scope: system colors (brand tokens come later), native `WKWebView` history
/// for back/forward, http for localhost hosts and https elsewhere.
public final class WebPaneSurface: NSObject, TerminalSurface {
    public weak var delegate: TerminalSurfaceDelegate?

    private let container: FocusReportingView
    private let webView: WKWebView
    private let webHost = NSView()
    private let backButton = WebPaneSurface.iconButton("chevron.left", "Back")
    private let forwardButton = WebPaneSurface.iconButton("chevron.right", "Forward")
    private let reloadButton = WebPaneSurface.iconButton("arrow.clockwise", "Reload")
    private let urlField = NSTextField()
    private let deviceControl = NSSegmentedControl()
    private let errorLabel = NSTextField(labelWithString: "")
    private var toolbar: NSStackView!

    private var device: DevicePreset
    private var pendingURL: URL
    private var focused = false

    /// Letterbox width constraints, swapped on device change. `fullWidth` pins the web
    /// view to the host (desktop); `fixedWidth` clamps it to a device width, centered,
    /// while an always-on `<= host` cap keeps it inside a narrow pane (maxWidth 100%).
    private var fullWidth: NSLayoutConstraint!
    private var fixedWidth: NSLayoutConstraint!

    private var observations: [NSKeyValueObservation] = []

    public init(url: URL, device: DevicePreset = .desktop) {
        self.pendingURL = url
        self.device = device
        self.container = FocusReportingView()
        self.webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()

        buildToolbar()
        buildWebArea()
        observe()
        container.onFocusRequest = { [weak self] in self?.requestFocus() }

        applyDevice(device, animated: false)
        load(url)
    }

    // MARK: TerminalSurface

    public var view: NSView { container }
    public var isFocused: Bool { focused }
    public var isBusy: Bool { webView.isLoading }
    public var title: String {
        if let t = webView.title, !t.isEmpty { return t }
        return webView.url?.host ?? pendingURL.host ?? "web"
    }

    public func start(_ config: TerminalSurfaceConfig) {}  // URL is injected at construction

    public func focus() {
        focused = true
        container.window?.makeFirstResponder(webView)
    }

    public func terminate() {
        webView.stopLoading()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }

    public func paste(_ text: String) {}
    public func copySelection() -> String? { nil }
    public func scrollToBottom() {}

    // MARK: Web-only API (reached by resolving the surface as WebPaneSurface)

    public func reload() {
        if webView.url == nil { load(pendingURL) } else { webView.reload() }
    }

    public func setDevice(_ device: DevicePreset) { applyDevice(device, animated: true) }

    public var currentURL: URL? { webView.url ?? pendingURL }

    // MARK: Navigation

    private func load(_ url: URL) {
        pendingURL = url
        errorLabel.isHidden = true
        webView.load(URLRequest(url: url))
        urlField.stringValue = url.absoluteString
    }

    /// Turn free text into a URL — scheme-less input gets http for loopback hosts and
    /// https otherwise, matching how you'd type `localhost:3000` vs `linear.app`.
    private func navigate(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized: String
        if trimmed.contains("://") {
            normalized = trimmed
        } else {
            let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
            let isLocal =
                host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1")
                || host.hasSuffix(".localhost")
            normalized = (isLocal ? "http://" : "https://") + trimmed
        }
        guard let url = URL(string: normalized) else { NSSound.beep(); return }
        load(url)
    }

    private func requestFocus() {
        focused = true
        delegate?.surfaceWantsFocus(self)
    }

    // MARK: Actions

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func didTapReload() { reload() }
    @objc private func urlSubmitted() { navigate(to: urlField.stringValue) }
    @objc private func deviceChanged() {
        applyDevice(DevicePreset.allCases[deviceControl.selectedSegment], animated: true)
    }

    // MARK: Layout

    private func applyDevice(_ device: DevicePreset, animated: Bool) {
        self.device = device
        deviceControl.selectedSegment = DevicePreset.allCases.firstIndex(of: device) ?? 0
        if let width = device.width {
            fullWidth.isActive = false
            fixedWidth.constant = width
            fixedWidth.isActive = true
        } else {
            fixedWidth.isActive = false
            fullWidth.isActive = true
        }
        guard animated else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            container.layoutSubtreeIfNeeded()
        }
    }

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    // MARK: Build

    private func buildToolbar() {
        container.translatesAutoresizingMaskIntoConstraints = false

        backButton.target = self; backButton.action = #selector(goBack)
        forwardButton.target = self; forwardButton.action = #selector(goForward)
        reloadButton.target = self; reloadButton.action = #selector(didTapReload)
        let navStack = NSStackView(views: [backButton, forwardButton, reloadButton])
        navStack.orientation = .horizontal
        navStack.spacing = 2

        urlField.target = self
        urlField.action = #selector(urlSubmitted)
        urlField.placeholderString = "Enter URL"
        urlField.font = .systemFont(ofSize: 11)
        urlField.bezelStyle = .roundedBezel
        urlField.focusRingType = .none
        urlField.lineBreakMode = .byTruncatingTail
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for (i, preset) in DevicePreset.allCases.enumerated() {
            deviceControl.segmentCount = DevicePreset.allCases.count
            deviceControl.setImage(
                NSImage(systemSymbolName: preset.symbol, accessibilityDescription: preset.label), forSegment: i)
            deviceControl.setWidth(30, forSegment: i)
        }
        deviceControl.trackingMode = .selectOne
        deviceControl.target = self
        deviceControl.action = #selector(deviceChanged)

        toolbar = NSStackView(views: [navStack, urlField, deviceControl])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func buildWebArea() {
        webHost.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webHost)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 8
        webView.layer?.masksToBounds = true
        webView.layer?.borderWidth = 1
        webView.layer?.borderColor = NSColor.separatorColor.cgColor
        webHost.addSubview(webView)

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        webHost.addSubview(errorLabel)

        fullWidth = webView.widthAnchor.constraint(equalTo: webHost.widthAnchor)
        fixedWidth = webView.widthAnchor.constraint(equalToConstant: 390)
        fixedWidth.priority = .defaultHigh

        // Toolbar sits above; the web area fills the rest. The web view is centered and
        // never exceeds the host so a narrow pane clamps a device preset (maxWidth 100%).
        NSLayoutConstraint.activate([
            webHost.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            webHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.topAnchor.constraint(equalTo: webHost.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webHost.bottomAnchor),
            webView.centerXAnchor.constraint(equalTo: webHost.centerXAnchor),
            webView.widthAnchor.constraint(lessThanOrEqualTo: webHost.widthAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: webHost.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: webHost.centerYAnchor),
        ])
    }

    private func observe() {
        webView.navigationDelegate = self
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                self.delegate?.surface(self, titleDidChange: self.title)
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                guard let self else { return }
                if let url = webView.url { self.urlField.stringValue = url.absoluteString }
                self.updateNavButtons()
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.updateNavButtons() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.updateNavButtons() },
        ]
    }

    private static func iconButton(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.setButtonType(.momentaryPushIn)
        button.toolTip = label
        return button
    }
}

extension WebPaneSurface: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorLabel.isHidden = true
        updateNavButtons()
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        showError(for: error)
    }

    public func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        showError(for: error)
    }

    private func showError(for error: Error) {
        let code = (error as NSError).code
        if code == NSURLErrorCancelled { return }  // superseded by a newer load
        let host = pendingURL.host ?? pendingURL.absoluteString
        errorLabel.stringValue = "Can't reach \(host).\nStart the server, then reload."
        errorLabel.isHidden = false
    }
}

/// A backing view that reports focus intent on click so the chrome routes unified
/// focus. Clicks inside the web view are consumed by WebKit; toolbar / gutter clicks
/// land here.
private final class FocusReportingView: NSView {
    var onFocusRequest: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.mouseDown(with: event)
    }
}

private extension DevicePreset {
    var symbol: String {
        switch self {
        case .desktop: return "display"
        case .tablet: return "ipad"
        case .phone: return "iphone"
        }
    }

    var label: String {
        switch self {
        case .desktop: return "Desktop"
        case .tablet: return "Tablet"
        case .phone: return "Phone"
        }
    }
}
