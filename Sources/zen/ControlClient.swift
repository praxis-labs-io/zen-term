import ControlProtocol
import Foundation

/// Sends one request over its own connection and waits for the matching response.
struct ControlClient {
    private static let replyTimeout: time_t = 10
    private static let maxReplyLength = 64 * 1024 * 1024

    let path: String
    let caller: ControlCaller?

    func send<Payload: ControlPayload>(_ cmd: ControlCommand, expecting: Payload.Type) throws(ZenFailure) -> Payload {
        let fd: Int32
        do {
            fd = try UnixSocket.connect(to: path)
        } catch {
            throw .noInstance("Couldn't connect to ZenTerm at \(path).")
        }
        defer { close(fd) }
        var timeout = timeval(tv_sec: Self.replyTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let request = ControlRequest(id: 1, cmd: cmd, caller: caller)
        guard let line = try? ControlWire.line(request), UnixSocket.writeAll(line, to: fd) else {
            throw .noInstance("Couldn't send the request to ZenTerm at \(path).")
        }
        let reply = try readLine(from: fd)
        let response: ControlResponse<Payload>
        do {
            response = try JSONDecoder().decode(ControlResponse<Payload>.self, from: reply)
        } catch {
            throw .app("ZenTerm sent a reply zen can't read.")
        }
        if let error = response.error { throw .app("\(error.message) (\(error.code.rawValue))") }
        guard response.ok, let result = response.result else { throw .app("ZenTerm sent an empty reply.") }
        return result
    }

    private func readLine(from fd: Int32) throws(ZenFailure) -> Data {
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while reply.count <= Self.maxReplyLength {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            reply.append(contentsOf: chunk[0..<n])
            if let newline = reply.firstIndex(of: 0x0A) { return reply.prefix(upTo: newline) }
        }
        throw .noInstance("ZenTerm closed the connection without answering.")
    }
}
