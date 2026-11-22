import AppLog
import ControlProtocol
import Foundation

typealias ControlReply = Result<any ControlPayload, ControlError>
typealias ControlRespond =
    @MainActor (ControlRequest, ControlHangup, @escaping @MainActor (ControlReply) -> Void) -> Void

final class ControlServer {
    static var socketPath: String { SocketListener.path(prefix: ControlEndpoint.fileNamePrefix) }

    static let answerTimeout = TimeInterval(ControlWire.longestReplyWait)

    // How often a held request checks that its client is still connected.
    private static let hangupCheck: TimeInterval = 0.5

    private let respond: ControlRespond
    private let idleTimeout: time_t
    private let answerTimeout: TimeInterval
    private let connections = DispatchQueue(
        label: "com.zenterm.control-connections", qos: .userInitiated, attributes: .concurrent)
    private var listener: SocketListener?

    init(
        path: String = ControlServer.socketPath, idleTimeout: time_t = 30,
        answerTimeout: TimeInterval = ControlServer.answerTimeout,
        respond: @escaping ControlRespond
    ) {
        self.respond = respond
        self.idleTimeout = idleTimeout
        self.answerTimeout = answerTimeout
        listener = SocketListener(
            prefix: ControlEndpoint.fileNamePrefix, path: path, name: "ControlSocket", category: .control
        ) { [weak self] conn in self?.acceptOne(conn) }
    }

    func start() { listener?.start() }

    func stop() { listener?.stop() }

    private func acceptOne(_ conn: Int32) {
        var timeout = timeval(tv_sec: idleTimeout, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
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
                guard line.count <= ControlWire.maxLineLength else { return refuseOverlongLine(on: fd) }
                guard let answer = reply(to: line, on: fd), UnixSocket.writeAll(answer, to: fd) else { return }
            }
            if pending.count > ControlWire.maxLineLength { return refuseOverlongLine(on: fd) }
        }
    }

    private func refuseOverlongLine(on fd: Int32) {
        let tooLong = ControlError(.badRequest, "The request line is longer than 64 KiB.")
        _ = UnixSocket.writeAll(Self.encoded(.failure(tooLong), id: nil), to: fd)
    }

    private func reply(to line: Data, on fd: Int32) -> Data? {
        switch ControlRequest.decode(line) {
        case .failure(let rejection):
            Log.info("ControlSocket: rejected a request, \(rejection.error.code.rawValue)", category: .control)
            return Self.encoded(.failure(rejection.error), id: rejection.id)
        case .success(let request):
            Log.info("ControlSocket: \(request.cmd.rawValue) id=\(request.id)", category: .control)
            return applyOnMain(request, on: fd).map { Self.encoded($0, id: request.id) }
        }
    }

    private func deadline(for request: ControlRequest) -> TimeInterval {
        request.cmd == .paneWait ? TimeInterval(ControlWire.answerWait(for: request.cmd, request.args)) : answerTimeout
    }

    // Nil when the client hung up first, which leaves nobody to answer.
    private func applyOnMain(_ request: ControlRequest, on fd: Int32) -> ControlReply? {
        final class Answer: @unchecked Sendable {
            private let lock = NSLock()
            private var reply: ControlReply?
            var settled: ControlReply? { lock.withLock { reply } }
            func settle(_ answer: ControlReply) -> Bool {
                lock.withLock {
                    guard reply == nil else { return false }
                    reply = answer
                    return true
                }
            }
        }
        let answer = Answer()
        let answered = DispatchSemaphore(value: 0)
        let hangup = ControlHangup()
        DispatchQueue.main.async { [respond] in
            MainActor.assumeIsolated {
                respond(request, hangup) { reply in
                    if answer.settle(reply) { answered.signal() }
                }
            }
        }
        let deadline = Date().addingTimeInterval(deadline(for: request))
        while answer.settled == nil, deadline.timeIntervalSinceNow > 0 {
            let slice = min(Self.hangupCheck, deadline.timeIntervalSinceNow)
            if answered.wait(timeout: .now() + slice) == .success { break }
            guard Self.hasHungUp(fd) else { continue }
            Log.info("ControlSocket: \(request.cmd.rawValue) id=\(request.id) lost its client", category: .control)
            if answer.settle(.failure(ControlError(.failed, "The client hung up."))) {
                DispatchQueue.main.async { hangup.hangUp() }
            }
            return nil
        }
        guard let reply = answer.settled else {
            Log.info("ControlSocket: \(request.cmd.rawValue) id=\(request.id) went unanswered", category: .control)
            return .failure(ControlError(.failed, "ZenTerm did not answer."))
        }
        return reply
    }

    // A peek that reads end-of-file means the peer closed; pending bytes are its next request.
    private static func hasHungUp(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
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
