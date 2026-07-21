import AppKit

/// Builds zen-term's main menu. Critically, Hide is bound to ⌘⇧H (NOT ⌘H), so ⌘H
/// stays free for pane-nav-left. Copy/Paste route to the `copyPaste` target's
/// `copyFromSurface:` / `pasteToSurface:` actions (the focused pane's surface).
enum MainMenu {
    static func install(copyPaste target: AnyObject?) {
        let main = NSMenu()

        // Application menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About ZenTerm",
            action: #selector(AppDelegate.showAbout(_:)),
            keyEquivalent: "")
        // Acknowledgements sits with About — it's app info (who we credit), not a Help topic. Nil
        // target routes it through the responder chain to the app delegate, like About.
        appMenu.addItem(
            withTitle: "Acknowledgements…",
            action: #selector(AppDelegate.showAcknowledgements(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        let hide = NSMenuItem(
            title: "Hide ZenTerm",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command, .shift]  // ⌘⇧H — frees ⌘H for nav-left
        appMenu.addItem(hide)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit ZenTerm",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        // Edit menu (Copy/Paste routed to the focused surface)
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        let copy = NSMenuItem(
            title: "Copy", action: #selector(PaneCanvasController.copyFromSurface(_:)), keyEquivalent: "c")
        copy.target = target
        editMenu.addItem(copy)
        let paste = NSMenuItem(
            title: "Paste", action: #selector(PaneCanvasController.pasteToSurface(_:)), keyEquivalent: "v")
        paste.target = target
        editMenu.addItem(paste)

        // Help menu — Export Diagnostics (ZEN-11). Nil target routes through the responder chain to
        // the app delegate, like About. macOS adds its standard search field to any menu titled
        // "Help"; that's expected. ZEN-212 adds Report an Issue here.
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        helpMenu.addItem(
            withTitle: "Export Diagnostics…",
            action: #selector(AppDelegate.exportDiagnostics(_:)),
            keyEquivalent: "")

        NSApp.mainMenu = main
    }
}
