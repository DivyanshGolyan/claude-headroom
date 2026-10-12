import Foundation
import Darwin

@MainActor
final class HeadroomServer {
    private var source: DispatchSourceRead?
    private var connections = 0
    private let engine: HeadroomEngine

    init(engine: HeadroomEngine) { self.engine = engine }

    func start(path: String = LocalSocket.path) throws {
        guard source == nil else { return }
        try LocalSocket.prepareDirectory((path as NSString).deletingLastPathComponent)
        let lock = open(path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw LocalSocket.failure("Cannot open the Headroom IPC lock.") }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == geteuid(), lockInfo.st_mode & 0o777 == 0o600 else {
            close(lock)
            throw LocalSocket.failure("The Headroom IPC lock is inaccessible.")
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno == EWOULDBLOCK ? "app_already_running" : "connection_error"
            close(lock)
            throw HeadroomFailure(code: code, message: "Another Headroom instance owns the CLI endpoint, or its lock is inaccessible.")
        }
        var descriptor: Int32 = -1
        var bound = false
        do {
            var info = stat()
            if lstat(path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else {
                    throw LocalSocket.failure("Refusing to replace a non-socket IPC path.")
                }
                guard unlink(path) == 0 else { throw LocalSocket.failure("Cannot remove the stale IPC socket.") }
            } else if errno != ENOENT { throw LocalSocket.failure("Cannot inspect the IPC socket.") }
            descriptor = try LocalSocket.make()
            var address = try LocalSocket.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw LocalSocket.failure("Cannot bind the Headroom IPC socket.") }
            bound = true
            guard chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else {
                throw LocalSocket.failure("Cannot listen on the Headroom IPC socket.")
            }
            let listener = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
            source.setEventHandler { [weak self] in self?.acceptConnections(listener) }
            source.setCancelHandler {
                close(listener)
                unlink(path)
                close(lock)
            }
            self.source = source
            source.resume()
        } catch {
            if descriptor >= 0 { close(descriptor) }
            if bound { unlink(path) }
            close(lock)
            throw error
        }
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }

    private func acceptConnections(_ listener: Int32) {
        // Bound work per main-loop turn and the number of slow clients held in memory.
        for _ in 0..<16 {
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            guard connections < 16 else { close(descriptor); continue }
            do {
                try LocalSocket.configure(descriptor)
                try LocalSocket.checkPeer(descriptor)
            } catch { close(descriptor); continue }
            connections += 1
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let request: Result<HeadroomRequest, Error>
                do {
                    let data = try LocalSocket.read(descriptor, deadline: .now.advanced(by: .seconds(3)), limit: 4096)
                    request = .success(try HeadroomJSON.decode(HeadroomRequest.self, from: data))
                } catch { request = .failure(error) }
                Task { @MainActor [weak self] in
                    guard let self else { close(descriptor); return }
                    let response = await self.handle(request)
                    DispatchQueue.global(qos: .utility).async {
                        defer { close(descriptor) }
                        if let data = try? HeadroomJSON.encode(response) {
                            try? LocalSocket.write(data, to: descriptor, deadline: .now.advanced(by: .seconds(3)))
                        }
                        Task { @MainActor in self.connections -= 1 }
                    }
                }
            }
        }
    }

    private func handle(_ request: Result<HeadroomRequest, Error>) async -> HeadroomResponse {
        switch request {
        case let .failure(error):
            return HeadroomResponse(data: nil, error: (error as? HeadroomFailure)
                ?? HeadroomFailure(code: "invalid_request", message: "Expected a status or refresh request in the Headroom JSON protocol."))
        case let .success(request):
            guard request.schema_version == HeadroomRequest.version else {
                return HeadroomResponse(data: nil, error: HeadroomFailure(code: "protocol_mismatch", message: "Update the app and CLI to compatible versions."))
            }
            switch request.operation {
            case .status: return HeadroomResponse(data: engine.status().api, error: nil)
            case .refresh:
                let result = await engine.refresh()
                return HeadroomResponse(data: result.status.api, error: result.error)
            }
        }
    }
}
