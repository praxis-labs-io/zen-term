import AppKit

/// Shared scaffolding for the Settings card's scrolling detail sections — the flipped-document
/// scroll wrapper and the Reset-all success flash — so each section doesn't re-hand-roll them.
enum SettingsDetail {
    /// Wrap a section's rows stack in the standard detail scroll: a flipped document (top-down
    /// coords, so it opens at the top), a slim auto-hiding overlay scroller, and the shared content
    /// insets (18 top/bottom, 20 leading/trailing). The rows stack becomes the document's content.
    static func scroll(for rowsStack: NSStackView) -> SettingsScrollView {
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)

        let scroll = SettingsScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = SlimScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 18),
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -18),
        ])
        return scroll
    }

    /// A section group caption: 10pt semibold, uppercased, muted ink. The identical builder lived
    /// in every settings section; the caller retains the returned label so `reapplyTheme` can
    /// recolor it (the ink role re-derives from `Theme.current` here).
    static func groupCaption(_ title: String) -> NSTextField {
        let caption = NSTextField(labelWithString: title.uppercased())
        caption.font = .systemFont(ofSize: 10, weight: .semibold)
        caption.textColor = Theme.current.chrome.ink(alpha: 0.4)
        return caption
    }

    /// The trailing hint that tells a reorderable list its rows can move. ⌥↑/⌥↓ is otherwise
    /// undiscoverable: nothing on a row suggests it. The caller retains the label so `reapplyTheme`
    /// can recolor it, and only builds one when there is more than one row, so the hint never
    /// advertises a keystroke that would do nothing.
    static func reorderHint() -> NSTextField {
        let hint = NSTextField(labelWithString: "⌥↑ ⌥↓ to reorder")
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = Theme.current.chrome.ink(alpha: 0.35)
        hint.setContentHuggingPriority(.required, for: .horizontal)
        return hint
    }

    /// A group caption with an optional hint pinned to its trailing edge. The caller pins the row's
    /// width to the list stack.
    static func headerRow(caption: NSTextField, hint: NSTextField?) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [caption, spacer] + (hint.map { [$0] } ?? []))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Move keyboard focus to the `delta`-neighbor of `stops` and scroll it into view — the shared
    /// core of every section's arrow-nav. `anchor` is the current stop's index (nil = none focused).
    /// `wrap` is off for arrows (a no-op at the ends) and on for Tab, which loops within the card.
    /// `scrollTarget` maps the destination stop to the view actually revealed (e.g. the whole row, so
    /// its inline message shows). AppKit doesn't scroll to a newly-focused responder on its own.
    ///
    /// Returns whether focus actually moved, so a caller can fall through when it didn't — Shift-Tab
    /// at the first stop exits to the nav rather than dying there.
    @discardableResult
    static func moveFocus(
        stops: [NSView], from anchor: Int?, delta: Int, wrap: Bool = false,
        scrollTarget: (NSView) -> NSView
    ) -> Bool {
        guard let next = KeyboardFocus.step(from: anchor, delta: delta, count: stops.count, wrap: wrap)
        else { return false }
        let target = stops[next]
        target.window?.makeFirstResponder(target)
        reveal(scrollTarget(target), stops: stops)
        return true
    }

    /// Scroll `view` in, along with the strip above it that belongs to it: a group caption, or the
    /// document's top inset when nothing focusable sits above. Revealing the stop alone parks that
    /// strip just off the top edge, so arrowing up to a group's first row hid the caption naming it.
    ///
    /// One position, computed once and handed to the glide. Two `scrollToVisible` calls (strip, then
    /// stop) reached the same place but stepped there, and every step of a held arrow snapped.
    static func reveal(_ view: NSView, stops: [NSView]) {
        guard let scroll = view.enclosingScrollView as? SettingsScrollView,
            let document = scroll.documentView
        else { return }
        let viewport = scroll.contentView.bounds.height
        let frame = view.convert(view.bounds, to: document)
        let padded = frame.insetBy(dx: 0, dy: -12)  // shared breathing room above and below a stop
        let previousBottom =
            stops
            .map { $0.convert($0.bounds, to: document).maxY }
            .filter { $0 <= frame.minY }
            .max() ?? document.bounds.minY

        // Aim past the edge the stop arrives at, rather than flush against it. A stop parked on the
        // boundary is off screen for as long as the glide is behind, and the slack is what the glide
        // has to be smooth in. Capped against a short pane, where a third of the clip is plenty.
        let margin = min(84, viewport / 3)
        let revealTop = min(previousBottom, padded.minY)
        var top = scroll.pendingTop
        if padded.maxY + margin > top + viewport { top = padded.maxY + margin - viewport }  // down
        if revealTop - margin < top { top = revealTop - margin }  // up: the strip comes with the stop
        if padded.maxY > top + viewport { top = padded.maxY - viewport }  // the stop outranks the strip
        scroll.glide(
            top: min(max(0, top), max(0, document.frame.height - viewport)), keeping: frame)
    }

    /// Wrap a control in a full-width row that right-aligns it: a leading spacer takes the slack so
    /// the control lands in the same right-hand column as the row editors. The caller pins the row's
    /// width to the list stack. Used for the Reset-all and Restart buttons (and the reset flash) so
    /// every button sits on the right, uniform with the field/segmented controls above.
    static func trailingRow(_ view: NSView) -> NSStackView {
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
}

/// The "Defaults restored." line tucked under a section's Reset-all button: a muted-accent label
/// that flashes on reset and auto-hides after a couple seconds. Shared by the Settings sections.
final class ResetFlashLabel: NSTextField {
    private var hideTimer: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 11, weight: .medium)
        textColor = Theme.current.chrome.accent.nsColor
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Show the message, then fade it after a beat. Re-flashing restarts the timer.
    func flash(_ text: String) {
        stringValue = text
        isHidden = false
        let hide = DispatchWorkItem { [weak self] in self?.isHidden = true }
        hideTimer?.cancel()
        hideTimer = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: hide)
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. Matches the accent
    /// role set once in `init`.
    func reapplyTheme() {
        textColor = Theme.current.chrome.accent.nsColor
    }
}
