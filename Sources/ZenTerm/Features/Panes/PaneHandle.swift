import Foundation
import TerminalKit

struct PaneHandle {
    let token: Int
    let surfaceID: SurfaceID
    let surface: TerminalSurface
    let drawer: DrawerEdge?
    let cwd: URL?
}
