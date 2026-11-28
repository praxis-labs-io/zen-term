import ControlProtocol
import Foundation

struct LaunchedPaneExit: Equatable {
    let token: Int
    let record: PaneRecord
    let exitCode: Int?
    let lastLines: String?
    let outputFile: URL?
    var pane: ListResult.Pane?
}
