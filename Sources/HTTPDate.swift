import Foundation

enum HTTPDate {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        return formatter
    }()

    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    static func retryDelay(_ header: String?, serverDate: Date?, localDate: Date) -> Duration {
        guard let text = header?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .seconds(300) }
        let seconds: Double
        if text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Double(text) {
            seconds = value
        } else if let date = parse(text) {
            seconds = date.timeIntervalSince(serverDate ?? localDate)
        } else { return .seconds(300) }
        guard seconds.isFinite, seconds <= Double(Int32.max) else { return .seconds(300) }
        return .seconds(max(60, seconds))
    }
}
