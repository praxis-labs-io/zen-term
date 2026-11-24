import Foundation
import TerminalKit

struct PaneHandle {
    enum Location: Equatable {
        case tree
        case drawer(DrawerEdge)
        case float
    }

    let token: Int
    let surfaceID: SurfaceID
    let surface: TerminalSurface
    let location: Location
    let cwd: URL?
    var record = PaneRecord()

    var drawer: DrawerEdge? {
        guard case .drawer(let edge) = location else { return nil }
        return edge
    }
}
