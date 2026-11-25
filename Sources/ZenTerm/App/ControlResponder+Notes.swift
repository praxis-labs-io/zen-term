import AppLog
import Foundation

extension ControlResponder {
    func tell(_ note: HelperNote) {
        guard let parent = parentPlace(of: note), !note.answeredWaits.contains(parent.pane.surfaceID) else { return }
        let isBlocked = { [self] in
            parentPlace(of: note).map { Self.refusal(.paste, into: $0, from: nil, force: nil) != nil } ?? false
        }
        let deliver = { [self] (overDraft: Bool) in
            guard let place = parentPlace(of: note), place.window.runsAgent(place.pane),
                place.pane.surface.isStarted, note.outlivesHelper || locate(pane: note.helper) != nil,
                !isStale(note)
            else { return }
            paste(note.text, from: note.helper, into: place, enter: true, overDraft: overDraft)
        }
        let drop = { (reason: String) in
            Log.warning("Dropped pane \(note.helper)'s note to pane \(note.parent): \(reason).", category: .control)
        }
        let setsDraftAside = { [self] in
            parentPlace(of: note).map { $0.window.draftStash(of: $0.pane) != nil } ?? false
        }
        paneDrafts.queue(
            parent.pane.surfaceID,
            PaneDrafts.Message(
                isTask: false, setsDraftAside: setsDraftAside, isBlocked: isBlocked, deliver: deliver, drop: drop))
    }

    private func isStale(_ note: HelperNote) -> Bool {
        guard case .blocked = note.change else { return false }
        guard let helper = locate(pane: note.helper) else { return true }
        return helper.window.listing(of: helper.pane, in: helper.tab).agent?.status != .blocked
    }

    private func parentPlace(of note: HelperNote) -> PanePlace? {
        locate(pane: note.parent).map { PanePlace(window: $0.window, tab: $0.tab, pane: $0.pane) }
    }
}
