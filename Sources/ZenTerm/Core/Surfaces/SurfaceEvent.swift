import TerminalKit

enum SurfaceEvent {
    case scrollPosition(TerminalScrollPosition)
    case selectionChanged
    case search(SearchController.Event)
}
