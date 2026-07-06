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

    override func bell(source: Terminal) {
        onBell?()
        super.bell(source: source)
    }
}
