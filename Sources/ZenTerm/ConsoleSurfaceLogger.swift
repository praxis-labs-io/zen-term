import Foundation
import TerminalKit

/// Prints the delegate events Epic 0 must observe. Other delegate methods use the
/// protocol's default no-ops.
final class ConsoleSurfaceLogger: TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, titleDidChange title: String) {
        print("[title] \(title)")
    }
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {
        print("[cwd] \(url.path)")
    }
    func surfaceDidRingBell(_ s: TerminalSurface) {
        print("[bell]")
    }
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {
        print("[notify] \(n.title): \(n.body)")
    }
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?) {
        print("[progress] \(p.map { "\($0.state) \($0.fraction ?? -1)" } ?? "cleared")")
    }
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        print("[exit] code=\(code.map(String.init) ?? "nil")")
    }
}
