import TerminalKit

enum SurfaceEvent {
    case scrollPosition(TerminalScrollPosition)
    case gridReflow
    case search(SearchController.Event)
}
