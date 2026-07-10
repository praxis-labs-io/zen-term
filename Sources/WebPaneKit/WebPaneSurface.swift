import AppKit
import TerminalKit
import WebKit

/// A `TerminalSurface` backed by a `WKWebView` — a pinned web pane that tiles in the
/// pane tree like any terminal. The surface owns only the letterboxed web content and
/// a control API (`goBack` / `goForward` / `reload` / `navigate` / `setDevice`); the
/// chrome builds the toolbar above it and drives that API. The device switch constrains
/// the web view's real width (no zoom) so responsive CSS reflows as it would on device.
public final class WebPaneSurface: NSObject, TerminalSurface {
    public weak var delegate: TerminalSurfaceDelegate?

    /// Fired when navigation state the toolbar reflects changes (address, back/forward
    /// availability). The chrome host sets this to refresh its header.
    public var onStateChange: (() -> Void)?

    private let container: FocusReportingView
    private let webView: WKWebView
    private let stageHost = WebStageHost()
    private let errorLabel = NSTextField(labelWithString: "")

    public private(set) var device: DevicePreset
    public private(set) var zoom: WebZoom = .fit
    private var pendingURL: URL

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
        stageHost.contentWidth = device.width
        onStateChange?()
    }

    public func setZoom(_ zoom: WebZoom) {
        self.zoom = zoom
        stageHost.zoom = zoom
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

    private func buildWebArea() {
        container.translatesAutoresizingMaskIntoConstraints = false

        stageHost.translatesAutoresizingMaskIntoConstraints = false
        stageHost.contentWidth = device.width
        stageHost.zoom = zoom
        container.addSubview(stageHost)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 12
        webView.layer?.masksToBounds = true
        webView.layer?.borderWidth = 1
        webView.layer?.borderColor = NSColor.separatorColor.cgColor
        stageHost.stage.addSubview(webView)

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        stageHost.addSubview(errorLabel)

        // The web view fills the stage (laid out at the device width); WebStageHost scales
        // the stage down to the pane. The error label stays unscaled, centered on the pane.
        NSLayoutConstraint.activate([
            stageHost.topAnchor.constraint(equalTo: container.topAnchor),
            stageHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stageHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stageHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.topAnchor.constraint(equalTo: stageHost.stage.topAnchor),
            webView.bottomAnchor.constraint(equalTo: stageHost.stage.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: stageHost.stage.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: stageHost.stage.trailingAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: stageHost.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: stageHost.centerYAnchor),
        ])
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
