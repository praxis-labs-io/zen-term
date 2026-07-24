import PaneKit

/// A terminal in the active tab that a diff comment can be sent to: a pane or an open drawer, named
/// the way the composer's dropdown lists it.
///
/// `id` lives in the tab's shared nav id space, so `TabController` resolves it back to a surface and
/// focuses that panel with the same call the ⌃-nav keys use. The chrome never holds the surface
/// itself: the viewer is handed a list of these and hands one back.
struct DiffSendTarget: Equatable {
    let id: PaneID
    let label: String
}
