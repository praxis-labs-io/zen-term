import AppLog
import ControlProtocol
import Foundation

typealias ControlReply = Result<any ControlPayload, ControlError>

/// Each request line decodes off-main, applies on main, and its reply is written back off-main, in order.
final class ControlServer {
    static var socketPath: String { SocketListener.path(prefix: ControlEndpoint.fileNamePrefix) }

    private let respond: @MainActor (ControlRequest) -> ControlReply
    private let idleTimeout: time_t
    private let connections = DispatchQueue(
        label: "com.zenterm.control-connections", qos: .userInitiated, attributes: .concurrent)
    private var listener: SocketListener?

    init(
        path: String = ControlServer.socketPath, idleTimeout: time_t = 30,
        respond: @escaping @MainActor (ControlRequest) -> ControlReply
    ) {
        self.respond = respond
        self.idleTimeout = idleTimeout
        listener = SocketListener(
            prefix: ControlEndpoint.fileNamePrefix, path: path, name: "ControlSocket", category: .control
        ) { [weak self] conn in self?.acceptOne(conn) }
    }

    func start() { listener?.start() }

    func stop() { listener?.stop() }

    private func acceptOne(_ conn: Int32) {
        var timeout = timeval(tv_sec: idleTimeout, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        connections.async { [weak self] in
            guard let self else {
                close(conn)
                return
            }
            self.serve(conn)
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return }
            pending.append(contentsOf: chunk[0..<n])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                guard UnixSocket.writeAll(reply(to: line), to: fd) else { return }
            }
            if pending.count > ControlWire.maxLineLength {
                let tooLong = ControlError(.badRequest, "The request line is longer than 64 KiB.")
                _ = UnixSocket.writeAll(Self.encoded(.failure(tooLong), id: nil), to: fd)
                return
            }
        }
    }

    private func reply(to line: Data) -> Data {
        switch ControlRequest.decode(line) {
        case .failure(let rejection):
            Log.info("ControlSocket: rejected a request, \(rejection.error.code.rawValue)", category: .control)
            return Self.encoded(.failure(rejection.error), id: rejection.id)
        case .success(let request):
            Log.info("ControlSocket: \(request.cmd.rawValue) id=\(request.id)", category: .control)
            return Self.encoded(applyOnMain(request), id: request.id)
        }
    }

    private func applyOnMain(_ request: ControlRequest) -> ControlReply {
        let answered = DispatchSemaphore(value: 0)
        var reply: ControlReply = .failure(ControlError(.failed, "ZenTerm did not answer."))
        DispatchQueue.main.async { [respond] in
            reply = MainActor.assumeIsolated { respond(request) }
            answered.signal()
        }
        answered.wait()
        return reply
    }

    private static func encoded(_ reply: ControlReply, id: Int?) -> Data {
        do {
            switch reply {
            case .success(let payload): return try payload.responseLine(id: id)
            case .failure(let error): return try error.responseLine(id: id)
            }
        } catch {
            let unencodable = ControlError(.failed, "The reply could not be encoded.")
            return (try? unencodable.responseLine(id: id)) ?? Data()
        }
    }
}
