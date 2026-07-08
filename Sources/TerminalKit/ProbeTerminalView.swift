import AppKit
import SwiftTerm

/// Probes whether the below-view-delegate callbacks (bell / notify / progress)
/// can be intercepted by subclassing `LocalProcessTerminalView`. Task 8 spike.
///
/// Verified against the SwiftTerm checkout (Mac/MacTerminalView.swift,
/// Terminal.swift): `TerminalView` conforms to `TerminalDelegate` and
/// implements `bell(source:)` as `open`, so it dispatches through the vtable
/// and a subclass override compiles and participates in dispatch. It
/// implements `progressReport(source:report:)` as `public` (not `open`), so a
/// subclass in another module cannot override it — the compiler rejects that
/// with "overriding non-open instance method outside of its defining module".
/// It does not implement `notify(source:title:body:)` at all (the
/// `TerminalDelegate` extension's no-op default applies), so there is no
/// superclass member to override — the compiler rejects that with "method
/// does not override any method from its superclass". `onNotify` / `onProgress`
/// are therefore omitted rather than forced with casts or non-override shadow
/// methods that would never receive dispatch.
final class ProbeTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?

    /// SwiftTerm keeps a caret on every pane and redraws it as a hollow outline
    /// (sometimes still blinking) whenever the view isn't first responder — and
    /// its internal `updateCursorPosition` re-adds the caret subview on every
    /// render, so an unfocused pane leaks the caret back the moment it produces
    /// output. There is no public switch for "no caret when unfocused"
    /// (`caretViewTracksFocus` only picks hollow-vs-filled), so we reach the
    /// caret subview directly and drive its `isHidden` from focus. `isHidden`
    /// persists across the subview being removed and re-added, so it stays gone
    /// until this pane is focused again. The caret is created once and never
    /// recreated, so the cached reference stays valid for the view's lifetime.
    private lazy var caretView: NSView? = subviews.first {
        String(describing: type(of: $0)) == "CaretView"
    }

    // The host window is chromeless and drags by its background
    // (`isMovableByWindowBackground`). AppKit converts any click-drag over a
    // subview whose `mouseDownCanMoveWindow` is true into a window move before
    // the view sees the event — and NSView defaults to true — so drags over
    // terminal content moved the window instead of reaching SwiftTerm's
    // selection. Opt this view out so click-drag here selects text; the window
    // still drags by the gutters, window inset, and chrome around the panes.
    override var mouseDownCanMoveWindow: Bool { false }

    override func bell(source: Terminal) {
        onBell?()
        super.bell(source: source)
    }

    // SwiftTerm seals `becomeFirstResponder`/`resignFirstResponder` as `public`
    // (not `open`), so they can't be overridden here — but it drives `hasFocus`
    // (an `open var`) from exactly those two callbacks, so overriding its setter
    // catches every focus transition.
    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            caretView?.isHidden = !newValue
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Panes enter the window unfocused; the focused pane reveals its own
        // caret via becomeFirstResponder. Without this a never-focused pane
        // (e.g. a fresh split) would keep SwiftTerm's default caret.
        if window?.firstResponder !== self { caretView?.isHidden = true }
    }
}
