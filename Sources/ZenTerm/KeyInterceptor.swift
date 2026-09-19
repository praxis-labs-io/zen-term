import AppKit

protocol KeybindCapturing: AnyObject {
    func beginCapture(_ handler: @escaping (NSEvent) -> Void)
    func endCapture()
}

protocol KeyModeHosting: AnyObject {
    var modeHandler: ((NSEvent) -> Bool)? { get set }
}

final class KeyInterceptor {
    enum ReservedChord: Hashable {
        case splitVertical, splitHorizontal
        case navLeft, navRight, navUp, navDown
        case prevPane, nextPane
        case closePane
        case closeTab, closeWindow
        case newTab, newWindow
        case selectTab(Int)
        case prevTab, nextTab
        case moveTabLeft, moveTabRight
        case renameTab
        case resizeLeft, resizeRight, resizeUp, resizeDown
        case toggleBottomDrawer
        case toggleRightDrawer
        case toggleZoom
        case fillScreen
        case toggleSidebar
        case focusSidebar
        case toggleToolFloat(String)
        case toggleRepoPicker
        case createWorktree
        case removeWorktree
        case toggleCommandPalette
        case openSettings
        case reloadConfig
        case checkForUpdates
        case reportIssue
        case newTool
        // App-wide: libghostty binds the same chords but applies each to the focused surface only.
        case increaseFontSize, decreaseFontSize, resetFontSize
        case toggleScrollMode
        case toggleSearch
        case scrollToTop, scrollToBottom, scrollPageUp, scrollPageDown
        case findNext, findPrevious, searchSelection
        case clearScreen, scrollToSelection
        // Three acts because the backend writes the file and disposes of the path in one call.
        case writeScreenFile, copyScreenFilePath, openScreenFile
        case selectAll, pasteSelection
        case jumpToPreviousPrompt, jumpToNextPrompt
        case dismissToast, dismissAllToasts
        case selectWorkspace(Int)
        case prevWorkspace, nextWorkspace
    }

    var onReservedChord: ((ReservedChord) -> Void)?

    var passThroughGuard: ((Chord, ReservedChord) -> Bool)?
    private var monitor: Any?

    private var keymap: [Chord: ReservedChord] = KeymapDefaults.map

    func setKeymap(_ map: [Chord: ReservedChord]) { keymap = map }

    private var captureHandler: ((NSEvent) -> Void)?

    func beginCapture(_ handler: @escaping (NSEvent) -> Void) { captureHandler = handler }
    func endCapture() { captureHandler = nil }

    // Consulted after chord routing, so a sticky mode can never swallow ⌘T or pane nav.
    var modeHandler: ((NSEvent) -> Bool)?

    // The responder chain hands `flagsChanged` to one pane, and every other pane needs it too.
    var onModifierChange: ((NSEvent) -> Void)?

    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.route(event)
        }
    }

    func route(_ event: NSEvent) -> NSEvent? {
        if let captureHandler {
            captureHandler(event)
            return nil
        }
        if event.type == .flagsChanged { onModifierChange?(event) }
        guard event.type == .keyDown else { return event }
        let reservableModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        if !event.modifierFlags.intersection(reservableModifiers).isEmpty {
            switch resolve(Chord(event: event)) {
            case .consume(let action):
                if !event.isARepeat || action.shouldRepeat { onReservedChord?(action) }
                return nil
            case .deferToTerminal:
                return event
            case .passThrough:
                break
            }
        }
        if modeHandler?(event) == true { return nil }
        return event
    }

    func resolve(_ chord: Chord?) -> Route {
        guard let chord, let action = keymap[chord] else { return .passThrough }
        if passThroughGuard?(chord, action) == true { return .deferToTerminal }
        return .consume(action)
    }

    // `passThrough` may still reach a sticky mode; `deferToTerminal` was handed to the program and must not.
    enum Route: Equatable {
        case passThrough
        case deferToTerminal
        case consume(ReservedChord)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}

extension KeyInterceptor: KeybindCapturing {}
extension KeyInterceptor: KeyModeHosting {}
