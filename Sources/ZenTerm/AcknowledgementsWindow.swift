import AppKit

/// A standalone window listing the third-party notices, opened from the app menu under About. Its
/// own window rather than the About panel's credits: the full license text is a long read that
/// crams into the About box as a wall of noise.
///
/// One shared window, reused across openings — a second invocation refocuses it rather than stacking
/// a duplicate. Unlike the system About panel (which follows `effectiveAppearance`), this is our own
/// chrome, so every color resolves from `Theme.current`, re-applied on each `show()` so a theme swap
/// while it was closed is picked up on reopen.
final class AcknowledgementsWindow {
    static let shared = AcknowledgementsWindow()

    private var window: NSWindow?
    private var textView: NSTextView?
    private var scrollView: NSScrollView?

    func show() {
        let window = window ?? build()
        applyTheme()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Acknowledgements"
        // Reused across openings, so it must survive its own close rather than being freed under us.
        window.isReleasedWhenClosed = false
        window.center()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = true
        scroll.autoresizingMask = [.width, .height]

        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        // License text is preformatted: monospace preserves the indentation and column alignment the
        // bodies rely on, which a proportional font would collapse.
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 20, height: 20)
        text.string = Self.notices()
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true

        scroll.documentView = text
        window.contentView = scroll

        self.window = window
        self.scrollView = scroll
        self.textView = text
        return window
    }

    private func applyTheme() {
        let chrome = Theme.current.chrome
        let background = chrome.background.nsColor
        window?.backgroundColor = background
        scrollView?.backgroundColor = background
        scrollView?.drawsBackground = true
        textView?.backgroundColor = background
        textView?.drawsBackground = true
        textView?.textColor = chrome.foreground.nsColor
    }

    private static func notices() -> String {
        guard
            let url = ZenTermResources.bundle.url(
                forResource: "THIRD-PARTY-NOTICES", withExtension: "md", subdirectory: "Resources"),
            let markdown = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return Acknowledgements.plainText(fromMarkdown: markdown)
    }
}
