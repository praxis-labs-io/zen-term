import Foundation
import TerminalKit

/// A live pane or drawer, addressed by its `$ZEN_PANE` token.
struct PaneHandle {
    let token: Int
    let surfaceID: SurfaceID
    let surface: TerminalSurface
    let drawer: DrawerEdge?
    let cwd: URL?
}
