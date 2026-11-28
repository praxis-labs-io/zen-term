import ControlProtocol
import Foundation

extension ControlResponder {
    func holdAwake(_ request: ControlRequest) -> ControlReply {
        if let duration = request.args.duration, duration < 1 {
            return .failure(ControlError(.badRequest, "awake.on needs a duration of a second or more."))
        }
        return awakePane(request).flatMap { keepAwake, pane in
            let name =
                pane.record.name
                ?? (pane.surface.title.isEmpty ? "pane \(pane.token)" : pane.surface.title)
            let refusal = keepAwake.startPaneHold(
                pane.surfaceID, pane: pane.token, name: name,
                for: request.args.duration.map(TimeInterval.init))
            if case .battery(let percent, let stop) = refusal {
                return .failure(
                    ControlError(.refused, "The battery is at \(percent)%, below the \(stop)% stop in Settings."))
            }
            return .success(Self.awakeResult(keepAwake, caller: pane.surfaceID))
        }
    }

    func endAwake(_ request: ControlRequest) -> ControlReply {
        awakePane(request).map { keepAwake, pane in
            keepAwake.endPaneHold(pane.surfaceID)
            return Self.awakeResult(keepAwake, caller: pane.surfaceID)
        }
    }

    func awakeStatus(_ request: ControlRequest) -> ControlReply {
        guard let keepAwake else { return .failure(Self.noKeepAwake) }
        let caller = request.caller?.pane.flatMap { locate(pane: $0)?.pane.surfaceID }
        return .success(Self.awakeResult(keepAwake, caller: caller))
    }

    private static let noKeepAwake = ControlError(.failed, "Keep Awake is not running.")

    private func awakePane(_ request: ControlRequest) -> Result<(KeepAwake, PaneHandle), ControlError> {
        guard let keepAwake else { return .failure(Self.noKeepAwake) }
        guard let token = request.caller?.pane else {
            return .failure(
                ControlError(.badRequest, "\(request.cmd.rawValue) holds for the pane it runs in. Run it in a pane."))
        }
        guard let found = locate(pane: token) else {
            return .failure(ControlError(.notFound, "There is no pane \(token)."))
        }
        return .success((keepAwake, found.pane))
    }

    private static func awakeResult(_ keepAwake: KeepAwake, caller: SurfaceID?) -> AwakeResult {
        let holds = keepAwake.paneHolds.map {
            AwakeResult.Hold(token: $0.pane, name: $0.name, remaining: keepAwake.secondsLeft($0))
        }
        let own = caller.flatMap { keepAwake.paneHold(of: $0) }.map {
            AwakeResult.Hold(token: $0.pane, name: $0.name, remaining: keepAwake.secondsLeft($0))
        }
        return AwakeResult(
            on: keepAwake.isOn, display: keepAwake.holdsDisplay, user: keepAwake.hold != nil, pane: own,
            panes: holds)
    }
}
