import ControlProtocol
import PaneKit
import TabKit
import TerminalKit

struct PanePlace {
    let window: WindowController
    let tab: TabID
    let pane: PaneHandle
}

extension ControlResponder {
    func pane(_ token: Int?, for request: ControlRequest) -> Result<PanePlace, ControlError> {
        if let token {
            guard let found = locate(pane: token) else {
                return .failure(ControlError(.notFound, "There is no pane \(token)."))
            }
            return .success(PanePlace(window: found.window, tab: found.tab, pane: found.pane))
        }
        return caller(request).flatMap { context in
            guard let tab = context.tab, let pane = context.pane ?? context.window.focusedPane(of: tab) else {
                return .failure(ControlError(.notFound, "No pane is open."))
            }
            return .success(PanePlace(window: context.window, tab: tab, pane: pane))
        }
    }

    func splitPane(_ request: ControlRequest) -> ControlReply {
        guard let direction = request.args.dir else {
            return .failure(ControlError(.badRequest, "pane.split needs a dir, right or down."))
        }
        return pane(request.args.pane, for: request).flatMap { place in
            let token = place.pane.token
            if place.pane.drawer != nil {
                return .failure(ControlError(.badRequest, "Pane \(token) is a drawer, and a drawer does not split."))
            }
            let command = request.args.cmd.flatMap { $0.isEmpty ? nil : $0 }
            switch place.window.splitPane(token, in: place.tab, axis: Self.axis(direction), command: command) {
            case nil:
                return .failure(ControlError(.notFound, "There is no pane \(token)."))
            case .focusMode:
                return .failure(
                    ControlError(.refused, "Pane \(token)'s tab is in Focus Mode. Exit Focus Mode to split."))
            case .tooSmall:
                return .failure(ControlError(.failed, "Pane \(token) is too small to split."))
            case .opened(let opened):
                if request.args.focus == true, let new = place.window.pane(token: opened) {
                    place.window.focus(new.pane.surfaceID, in: new.tab)
                    raise(place.window)
                }
                return .success(PaneResult(pane: opened))
            }
        }
    }

    private static func axis(_ direction: PaneDirection) -> SplitAxis {
        switch direction {
        case .right: return .vertical
        case .down: return .horizontal
        }
    }

    func focusPane(_ request: ControlRequest) -> ControlReply {
        pane(request.args.pane, for: request).map { place in
            place.window.focus(place.pane.surfaceID, in: place.tab)
            raise(place.window)
            return NoPayload()
        }
    }

    func closePane(_ request: ControlRequest) -> ControlReply {
        pane(request.args.pane, for: request).flatMap { place in
            let token = place.pane.token
            if place.pane.drawer != nil {
                return .failure(ControlError(.badRequest, "Pane \(token) is a drawer, which pane.close leaves open."))
            }
            guard let stakes = place.window.closeStakes(pane: place.pane, in: place.tab) else {
                return .failure(ControlError(.notFound, "There is no pane \(token)."))
            }
            if stakes.needsForce, request.args.force != true {
                return .failure(Self.refusal(closing: "pane \(token)", stakes))
            }
            place.window.removePane(token, in: place.tab)
            return .success(NoPayload())
        }
    }

    func sendToPane(_ request: ControlRequest) -> ControlReply {
        guard let text = request.args.text else {
            return .failure(ControlError(.badRequest, "pane.send needs text."))
        }
        return pane(request.args.pane, for: request).map { place in
            if !text.isEmpty { place.pane.surface.paste(text) }
            if request.args.enter == true { place.pane.surface.submit() }
            return NoPayload()
        }
    }

    func readPane(_ request: ControlRequest) -> ControlReply {
        if let lines = request.args.lines, lines < 1 {
            return .failure(ControlError(.badRequest, "lines must be 1 or more."))
        }
        return pane(request.args.pane, for: request).flatMap { place in
            let surface = place.pane.surface
            let text: String?
            if let lines = request.args.lines {
                text = surface.text(lastLines: lines)
            } else {
                text = Self.viewport(of: surface)
            }
            guard let text else {
                return .failure(ControlError(.failed, "Pane \(place.pane.token) could not be read."))
            }
            return .success(PaneText(text: text))
        }
    }

    private static func viewport(of surface: TerminalSurface) -> String? {
        guard let rows = surface.cellMetrics?.rows else { return nil }
        var lines = (0..<rows).map { surface.text(viewportRow: $0) ?? "" }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
