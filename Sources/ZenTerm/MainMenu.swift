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
        appMenu.addItem(withTitle: "About zen-term",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide zen-term",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command, .shift]   // ⌘⇧H — frees ⌘H for nav-left
        appMenu.addItem(hide)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit zen-term",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // Edit menu (Copy/Paste routed to the focused surface)
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        let copy = NSMenuItem(title: "Copy", action: Selector(("copyFromSurface:")), keyEquivalent: "c")
        copy.target = target
        editMenu.addItem(copy)
        let paste = NSMenuItem(title: "Paste", action: Selector(("pasteToSurface:")), keyEquivalent: "v")
        paste.target = target
        editMenu.addItem(paste)

        NSApp.mainMenu = main
    }
}
