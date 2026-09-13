import AppKit

/// `MenuShortcuts` reads this menu and refuses any keymap bind that lands on one of its key equivalents.
enum MainMenu {
    /// Edit items take AppKit selectors with no target, so a focused field editor serves them ahead of the window.
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About ZenTerm",
            action: #selector(AppDelegate.showAbout(_:)),
            keyEquivalent: "")
        appMenu.addItem(
            withTitle: "Acknowledgements…",
            action: #selector(AppDelegate.showAcknowledgements(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide ZenTerm",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit ZenTerm",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(
            withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

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
