import Foundation

/// Connecting to, and writing on, an `AF_UNIX` stream socket.
public enum UnixSocket {
    public enum ConnectError: Error, Equatable {
        case pathTooLong
        case socket(errno: Int32)
        case connect(errno: Int32)
    }

    /// Nil when `path` does not fit `sun_path`.
    public static func address(for path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = byte }
                dst[pathBytes.count] = 0
            }
        }
        return addr
    }

    /// Returns a connected descriptor with `SIGPIPE` off, which the caller closes.
    public static func connect(to path: String) throws(ConnectError) -> Int32 {
        guard var addr = address(for: path) else { throw .pathTooLong }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .socket(errno: errno) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            throw .connect(errno: code)
        }
        disableSigpipe(on: fd)
        return fd
    }

    /// A write to a peer that hung up then fails with `EPIPE` instead of killing the process.
    public static func disableSigpipe(on fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data`. False when the peer is gone or the write fails.
    public static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, cursor, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                cursor += written
                remaining -= written
            }
            return true
        }
    }
}
