import AppKit
import TerminalKit
import WebKit

/// A `TerminalSurface` backed by a `WKWebView` — a pinned web pane that tiles in the
/// pane tree like any terminal. The surface owns only the letterboxed web content and
/// a control API (`goBack` / `goForward` / `reload` / `navigate` / `setDevice` /
/// `setPageZoom`); the chrome builds the toolbar above it and drives that API. The
/// device switch constrains the web view window's width (reflow); page zoom scales the
/// rendered content inside that window without resizing it.
public final class WebPaneSurface: NSObject, TerminalSurface {
    public weak var delegate: TerminalSurfaceDelegate?

    /// Fired when navigation state the toolbar reflects changes (address, back/forward
    /// availability). The chrome host sets this to refresh its header.
    public var onStateChange: (() -> Void)?

    private let container: FocusReportingView
    private let webView: WKWebView
    private let webHost = NSView()
    private let errorLabel = NSTextField(labelWithString: "")

    public private(set) var device: DevicePreset
    public private(set) var pageZoom: CGFloat = 1
    private var pendingURL: URL

    /// Constraint groups swapped on device change. Desktop fills the pane; a device
    /// preset sizes the window to its real dimensions (aspect-locked), centered and
    /// scaled to fit via always-on `<= host` caps.
    private var desktopConstraints: [NSLayoutConstraint] = []
    private var deviceConstraints: [NSLayoutConstraint] = []
    private var fixedWidth: NSLayoutConstraint!
    private var fixedHeight: NSLayoutConstraint!
    private var aspect: NSLayoutConstraint?

    private var observations: [NSKeyValueObservation] = []

    public init(url: URL, device: DevicePreset = .desktop) {
        self.pendingURL = url
        self.device = device
        self.container = FocusReportingView()
        self.webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()

        buildWebArea()
        observe()
        container.onFocusRequest = { [weak self] in self?.requestFocus() }

        load(url)
    }

    // MARK: TerminalSurface

    public var view: NSView { container }
    public var isFocused: Bool { container.window?.firstResponder === webView }
    public var isBusy: Bool { webView.isLoading }
    public var title: String {
        if let t = webView.title, !t.isEmpty { return t }
        return webView.url?.host ?? pendingURL.host ?? "web"
    }

    public func start(_ config: TerminalSurfaceConfig) {}  // URL is injected at construction

    public func focus() { container.window?.makeFirstResponder(webView) }

    public func terminate() {
        webView.stopLoading()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }

    public func paste(_ text: String) {}
    public func copySelection() -> String? { nil }
    public func scrollToBottom() {}

    // MARK: Control API (driven by the chrome toolbar)

    public var canGoBack: Bool { webView.canGoBack }
    public var canGoForward: Bool { webView.canGoForward }
    public var addressText: String { webView.url?.absoluteString ?? pendingURL.absoluteString }

    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }
    public func reload() {
        if webView.url == nil { load(pendingURL) } else { webView.reload() }
    }

    public func setDevice(_ device: DevicePreset) {
        self.device = device
        applyDevice()
        onStateChange?()
    }

    /// Scale the rendered page inside the fixed web view window (browser-style zoom) —
    /// the window is untouched, only the content resolution changes.
    public func setPageZoom(_ factor: CGFloat) {
        pageZoom = factor
        webView.pageZoom = factor
        onStateChange?()
    }

    /// Turn free text into a URL — scheme-less input gets http for loopback hosts and
    /// https otherwise, matching how you'd type `localhost:3000` vs `linear.app`.
    public func navigate(to text: String) {
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

    // MARK: Internals

    private func load(_ url: URL) {
        pendingURL = url
        errorLabel.isHidden = true
        webView.load(URLRequest(url: url))
        onStateChange?()
    }

    private func requestFocus() { delegate?.surfaceWantsFocus(self) }

    /// Swap constraint groups for the current device — desktop fills the pane; a device
    /// preset locks the window to its aspect ratio at native size, scaled down to fit.
    private func applyDevice() {
        NSLayoutConstraint.deactivate(desktopConstraints + deviceConstraints)
        aspect?.isActive = false
        if let size = device.size {
            fixedWidth.constant = size.width
            fixedHeight.constant = size.height
            let ratio = webView.widthAnchor.constraint(
                equalTo: webView.heightAnchor, multiplier: size.width / size.height)
            aspect = ratio
            NSLayoutConstraint.activate(deviceConstraints + [ratio])
        } else {
            NSLayoutConstraint.activate(desktopConstraints)
        }
    }

    private func buildWebArea() {
        container.translatesAutoresizingMaskIntoConstraints = false

        webHost.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webHost)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 12
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

        // Desktop: fill the pane. Device: native size at high priority, aspect-locked and
        // centered, scaled down by the always-on `<= host` caps when the pane is smaller.
        let fullWidth = webView.widthAnchor.constraint(equalTo: webHost.widthAnchor)
        desktopConstraints = [
            fullWidth,
            webView.topAnchor.constraint(equalTo: webHost.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webHost.bottomAnchor),
        ]
        fixedWidth = webView.widthAnchor.constraint(equalToConstant: 390)
        fixedWidth.priority = .defaultHigh
        fixedHeight = webView.heightAnchor.constraint(equalToConstant: 844)
        fixedHeight.priority = .defaultHigh
        deviceConstraints = [
            fixedWidth, fixedHeight,
            webView.centerYAnchor.constraint(equalTo: webHost.centerYAnchor),
        ]

        NSLayoutConstraint.activate([
            webHost.topAnchor.constraint(equalTo: container.topAnchor),
            webHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.centerXAnchor.constraint(equalTo: webHost.centerXAnchor),
            webView.widthAnchor.constraint(lessThanOrEqualTo: webHost.widthAnchor),
            webView.heightAnchor.constraint(lessThanOrEqualTo: webHost.heightAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: webHost.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: webHost.centerYAnchor),
        ])
        applyDevice()
    }

    private func observe() {
        webView.navigationDelegate = self
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                self.delegate?.surface(self, titleDidChange: self.title)
            },
            webView.observe(\.url) { [weak self] _, _ in self?.onStateChange?() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.onStateChange?() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.onStateChange?() },
        ]
    }
}

extension WebPaneSurface: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorLabel.isHidden = true
        onStateChange?()
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
/// focus. Clicks inside the web view are consumed by WebKit; gutter clicks land here.
private final class FocusReportingView: NSView {
    var onFocusRequest: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.mouseDown(with: event)
    }
}
