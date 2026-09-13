import AppKit

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
