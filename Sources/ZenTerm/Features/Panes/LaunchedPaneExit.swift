import ControlProtocol

struct LaunchedPaneExit: Equatable {
    let token: Int
    let record: PaneRecord
    let exitCode: Int?
    let lastLines: String?
    var pane: ListResult.Pane?
}
