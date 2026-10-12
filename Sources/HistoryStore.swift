import Foundation
import Darwin

struct HistoryStore {
    let url: URL

    init(url: URL) {
        self.url = url
        try? prepareDirectory()
    }

    func load() -> History? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let limit = 256 * 1024
        guard let size = try? file.seekToEnd(), size <= limit,
              (try? file.seek(toOffset: 0)) != nil,
              let data = try? file.read(upToCount: limit + 1), data.count <= limit,
              var history = try? JSONDecoder().decode(History.self, from: data) else { return nil }
        history.retainRecentSuffix()
        return history
    }

    private func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func save(_ history: History) throws {
        let data = try JSONEncoder().encode(history)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".history-\(UUID().uuidString)")
        var descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if descriptor < 0 && errno == ENOENT {
            try prepareDirectory()
            descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            try file.close()
        } catch {
            try? file.close()
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
