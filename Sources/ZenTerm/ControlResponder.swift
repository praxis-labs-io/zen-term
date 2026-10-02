import ControlProtocol
import TabKit

@MainActor
struct ControlResponder {
    let windows: () -> [WindowController]

    func respond(to request: ControlRequest) -> ControlReply {
        switch request.cmd {
        case .hello: return .success(HelloResult(app: AppVersion.current))
        case .list: return .success(ListResult(windows: windows().map { $0.listing() }))
        }
    }

    func locate(pane token: Int) -> (window: WindowController, tab: TabID, pane: PaneHandle)? {
        for window in windows() {
            if let (tab, pane) = window.pane(token: token) { return (window, tab, pane) }
        }
        return nil
    }
}
