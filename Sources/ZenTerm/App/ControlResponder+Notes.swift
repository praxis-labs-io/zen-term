import Foundation

extension ControlResponder {
    func tell(_ note: HelperNote) {
        guard let parent = parentPlace(of: note), !note.answeredWaits.contains(parent.pane.surfaceID) else { return }
        hold(note, by: parentNotes.now().addingTimeInterval(ParentNotes.longestHold))
    }

    private func hold(_ note: HelperNote, by cap: Date) {
        let isBlocked = { [self] in
            parentPlace(of: note).map { Self.refusal(sending: $0, from: nil, force: nil) != nil } ?? false
        }
        parentNotes.hold(by: cap, whileBlocked: isBlocked) { [self] in
            guard let parent = parentPlace(of: note) else { return }
            paneDrafts.hold(parent.pane.surfaceID, hangup: ControlHangup()) { [self] in
                guard let place = parentPlace(of: note), place.window.runsAgent(place.pane),
                    place.pane.surface.isStarted, note.outlivesHelper || locate(pane: note.helper) != nil
                else { return }
                if isBlocked() { return hold(note, by: cap) }
                paste(note.text, from: note.helper, into: place, enter: true)
            }
        }
    }

    private func parentPlace(of note: HelperNote) -> PanePlace? {
        locate(pane: note.parent).map { PanePlace(window: $0.window, tab: $0.tab, pane: $0.pane) }
    }
}
