import Foundation
import Darwin

enum LocalSocket {
    static var directory: String { "/tmp/com.divyanshgolyan.headroom-\(geteuid())" }
    static var path: String { directory + "/control.sock" }
    static let maximumFrameSize = 256 * 1024

    static func prepareDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw failure("Cannot create the local IPC directory.") }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw failure("The local IPC directory must be owned by this user with mode 0700.")
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw failure("The local socket path is too long.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func make() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw failure("Cannot create the local socket.") }
        do { try configure(descriptor) } catch { close(descriptor); throw error }
        return descriptor
    }

    static func configure(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw failure("Cannot configure the local socket.")
        }
    }

    static func checkPeer(_ descriptor: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid() else {
            throw failure("The local socket peer is not the current user.")
        }
    }

    static func connect(to path: String, deadline: ContinuousClock.Instant) throws -> Int32 {
        let descriptor = try make()
        do {
            var address = try address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                if errno == ENOENT || errno == ECONNREFUSED {
                    throw HeadroomFailure(code: "app_not_running", message: "Open Headroom before using the CLI. If it is already running, update it to a version with CLI support.")
                }
                guard errno == EINPROGRESS else { throw failure("Cannot connect to Headroom.") }
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                    throw failure("Cannot connect to Headroom.")
                }
            }
            try checkPeer(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func read(_ descriptor: Int32, deadline: ContinuousClock.Instant, limit: Int = maximumFrameSize) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw failure("Headroom disconnected before completing the response.") }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw HeadroomFailure(code: "invalid_request", message: "The local IPC message is too large.") }
            if let end = data.firstIndex(of: 10) {
                guard end == data.count - 1 else { throw HeadroomFailure(code: "invalid_request", message: "Send exactly one JSON message per connection.") }
                data.removeLast()
                return data
            }
        }
    }

    static func write(_ data: Data, to descriptor: Int32, deadline: ContinuousClock.Instant) throws {
        guard data.count < maximumFrameSize else { throw failure("The local IPC response is too large.") }
        var frame = data
        frame.append(10)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                let count = send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw failure("Headroom disconnected before completing the request.") }
                offset += count
            }
        }
    }

    private static func wait(_ descriptor: Int32, events: Int16, deadline: ContinuousClock.Instant) throws {
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds > 0 else { throw HeadroomFailure(code: "timeout", message: "Timed out waiting for Headroom. A shared refresh may still complete in the app.") }
            var descriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(ceil(seconds * 1000), Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw failure("Cannot wait for the local socket.") }
            if result == 0 { continue }
            if ContinuousClock.now >= deadline { continue }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw failure("The local socket was closed.") }
            return
        }
    }

    static func failure(_ message: String) -> HeadroomFailure {
        HeadroomFailure(code: "connection_error", message: message)
    }
}
