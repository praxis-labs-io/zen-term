import AppKit

/// Builds zen-term's main menu.
///
/// **Every key equivalent here is off limits to the keymap.** `MenuShortcuts` reads this menu at
/// keymap-assembly time and refuses any bind that lands on one, so adding a shortcut here protects
/// it with no list to update. It also means a shortcut added here silently takes that chord away
/// from a keybind, which is the trade: the menu is the smaller, more visible surface.
enum MainMenu {
    /// Select All's chord, which the menu holds and the keymap does not (ZEN-370). The item is built
    /// from it and the command palette reads it, so ⌘A is spelled once. Command-only: the item takes
    /// `NSMenuItem`'s default ⌘ mask, and `MainMenuTests` reads the built item back to prove it.
    static let selectAllChord = Chord(command: true, key: "a")

    static func install() {
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
        // Hide has no shortcut. A menu key equivalent loses to the keymap every time, because
        // `KeyInterceptor` resolves ahead of `NSApp.sendEvent`, so a chord both want leaves the
        // item dead with the menu still drawing the shortcut beside it.
        appMenu.addItem(
            withTitle: "Hide ZenTerm",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit ZenTerm",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        // Edit menu. AppKit's own selectors, no target, so the responder chain decides: a focused
        // field editor implements all three and takes them ahead of the window, and `WindowController`
        // implements them as the terminal endpoint for everything below. A custom selector here
        // instead (`copyFromSurface:`) walks straight past the field, which is what left ⌘C in the
        // find bar copying the buffer behind it (ZEN-370).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(
            withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
            keyEquivalent: selectAllChord.key)

        // Help menu — Export Diagnostics (ZEN-11). Nil target routes through the responder chain to
        // the app delegate, like About. macOS adds its standard search field to any menu titled
        // "Help"; that's expected. ZEN-212 adds Report an Issue here.
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        helpMenu.addItem(
            withTitle: "Report an Issue…",
            action: #selector(AppDelegate.reportAnIssue(_:)),
            keyEquivalent: "")
        helpMenu.addItem(
            withTitle: "Export Diagnostics…",
            action: #selector(AppDelegate.exportDiagnostics(_:)),
            keyEquivalent: "")

        NSApp.mainMenu = main
    }
}
