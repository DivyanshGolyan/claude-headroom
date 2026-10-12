import Foundation

struct QuotaWindow: Codable {
    let id: String
    let used: Double
    let reset: Date
    let name: String
}

struct UsageSample: Codable {
    let date: Date
    let used: Double
    let reset: Date?
    var weekly: [QuotaWindow]? = nil
}

struct UsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double
        let resets_at: String?
    }
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let display_name: String? }
            let model: Model?
        }
        let kind: String
        let group: String?
        let percent: Double
        let resets_at: String?
        let is_active: Bool?
        let scope: Scope?
    }
    let five_hour: Window?
    let seven_day: Window?
    let seven_day_opus: Window?
    let limits: [Limit]?

    private enum CodingKeys: String, CodingKey { case five_hour, seven_day, seven_day_opus, limits }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.five_hour) else {
            throw UsageError.message("Claude's usage response no longer contains a five-hour window field.")
        }
        five_hour = try container.decodeIfPresent(Window.self, forKey: .five_hour)
        seven_day = try container.decodeIfPresent(Window.self, forKey: .seven_day)
        seven_day_opus = try container.decodeIfPresent(Window.self, forKey: .seven_day_opus)
        limits = try container.decodeIfPresent([Limit].self, forKey: .limits)
    }

    func sample(at date: Date) throws -> UsageSample {
        var weekly: [QuotaWindow] = []
        if let limits {
            for limit in limits where limit.group == "weekly" || limit.kind.hasPrefix("weekly") {
                guard limit.is_active != false else { continue }
                let model = limit.scope?.model?.display_name
                // Match the existing headroom CLI: general and Opus limits gate this app.
                guard model == nil || model!.localizedCaseInsensitiveContains("opus") else { continue }
                guard let reset = limit.resets_at.flatMap(Self.parseDate), Self.valid(limit.percent) else {
                    throw UsageError.message("Claude returned an invalid weekly limit.")
                }
                weekly.append(QuotaWindow(id: limit.kind + (model ?? ""), used: limit.percent,
                                          reset: reset, name: model == nil ? "Weekly" : "Opus"))
            }
        } else {
            for (id, name, window) in [("weekly", "Weekly", seven_day), ("opus", "Opus", seven_day_opus)] {
                guard let window else { continue }
                guard Self.valid(window.utilization), let reset = window.resets_at.flatMap(Self.parseDate) else {
                    throw UsageError.message("Claude returned an invalid weekly limit.")
                }
                weekly.append(QuotaWindow(id: id, used: window.utilization, reset: reset, name: name))
            }
        }
        guard let window = five_hour else {
            return UsageSample(date: date, used: 0, reset: nil, weekly: weekly)
        }
        guard Self.valid(window.utilization) else { throw UsageError.message("Claude returned invalid five-hour usage.") }
        guard let text = window.resets_at else {
            guard window.utilization == 0 else { throw UsageError.message("Claude returned usage without a reset time.") }
            return UsageSample(date: date, used: 0, reset: nil, weekly: weekly)
        }
        guard let reset = Self.parseDate(text) else { throw UsageError.message("Claude returned an invalid reset time.") }
        return UsageSample(date: date, used: window.utilization, reset: reset, weekly: weekly)
    }

    private static func valid(_ used: Double) -> Bool { used.isFinite && (0...100).contains(used) }

    private static let dateLock = NSLock()
    private static let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeDate = ISO8601DateFormatter()

    static func parseDate(_ text: String) -> Date? {
        dateLock.lock()
        defer { dateLock.unlock() }
        return fractionalDate.date(from: text) ?? wholeDate.date(from: text)
    }

}

enum UsageError: Error {
    case message(String)
    case signedOut
    case rateLimited(Duration, receivedAt: ContinuousClock.Instant)
}

enum Clock {
    static func deadline(_ date: Date, relativeTo now: Date, seconds: Bool = false,
        locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        var style = Date.FormatStyle(date: .omitted, time: seconds ? .standard : .shortened,
            locale: locale, calendar: calendar, timeZone: timeZone)
        if !calendar.isDate(date, inSameDayAs: now) {
            style = style.day().month(.abbreviated)
            if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
                style = style.year()
            }
        }
        return date.formatted(style)
    }

    static func displayReset(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    static func resolvedFormat(day: Bool, locale: Locale = .current) -> String {
        DateFormatter.dateFormat(fromTemplate: day ? "EEEjmm" : "jmm", options: 0, locale: locale) ?? "HH:mm"
    }

    private static let lock = NSLock()
    private static var environment: (Locale, TimeZone)?
    private static var formatters: [Int: (format: String, formatter: DateFormatter)] = [:]

    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        environment = nil
        formatters.removeAll()
    }

    static func time(_ date: Date, day: Bool = false, period: Bool = false, locale: Locale = .current) -> String {
        lock.lock()
        defer { lock.unlock() }
        let zone = NSTimeZone.default
        if environment?.0 != locale || environment?.1 != zone {
            environment = (locale, zone)
            formatters.removeAll()
        }
        let key = (day ? 2 : 0) + (period ? 1 : 0)
        let format = resolvedFormat(day: day, locale: locale)
        let formatter: DateFormatter
        if let cached = formatters[key], cached.format == format { formatter = cached.formatter }
        else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = zone
            formatter.dateFormat = period ? format : format.replacingOccurrences(of: "\\s*[abB]\\s*", with: "", options: .regularExpression)
            formatters[key] = (format, formatter)
        }
        return formatter.string(from: date).trimmingCharacters(in: .whitespaces)
    }
}

enum Forecast: Equatable {
    static let maximumSampleAge: TimeInterval = 15 * 60
    case estimating, awaitingUpdate, stale, ready, onTrack
    case gap(Date, Date, String? = nil)
    case out(Date, String? = nil)
    case spare(Int, Date)

    private static let minimumObservationSpan: TimeInterval = 60
    private static let serverTimestampResolution: TimeInterval = 1

    static func counterObservations(_ counters: [(Date, Double, Date?)]) -> [(Date, Double)] {
        var observations: [(Date, Double)] = []
        var previous: (Date, Double, Date?)?
        var total = 0.0
        for counter in counters {
            if let previous {
                let sameWindow: Bool
                switch (previous.2, counter.2) {
                case let (left?, right?): sameWindow = abs(left.timeIntervalSince(right)) < 60
                case (nil, nil): sameWindow = true
                default: sameWindow = false
                }
                if sameWindow && counter.1 >= previous.1 {
                    total += counter.1 - previous.1
                } else if !sameWindow && (previous.2.map { $0.timeIntervalSince(counter.0) < serverTimestampResolution } ?? true)
                    && (counter.2.map { next in previous.2.map { next > $0 } ?? true } ?? true) {
                    // The new counter contributes usage since reset, never a negative delta.
                    total += counter.1
                } else {
                    observations.removeAll()
                    total = 0
                }
            }
            observations.append((counter.0, total))
            previous = counter
        }
        return observations
    }

    static func rate(_ observations: [(Date, Double)], minutes: Double) -> Double? {
        guard let first = observations.first, let latest = observations.last,
              latest.0.timeIntervalSince(first.0) >= minimumObservationSpan else { return nil }
        let cutoff = latest.0.addingTimeInterval(-minutes * 60)
        var baseline = first
        for (left, right) in zip(observations, observations.dropFirst()) where left.0 <= cutoff {
            baseline = left
            if right.0 > cutoff {
                let fraction = cutoff.timeIntervalSince(left.0) / right.0.timeIntervalSince(left.0)
                baseline = (cutoff, left.1 + fraction * (right.1 - left.1))
            }
        }
        let elapsed = latest.0.timeIntervalSince(baseline.0)
        guard elapsed >= minimumObservationSpan else { return nil }
        return max(0, latest.1 - baseline.1) / elapsed
    }

    static func calculate(samples: [UsageSample], now: Date) -> Forecast {
        guard let latest = samples.last else { return .estimating }
        guard (0...maximumSampleAge).contains(now.timeIntervalSince(latest.date)) else { return .stale }
        var gaps: [(Date, Date, String?)] = []
        var sessionSpare: Double?

        func evaluate(used: Double, reset: Date, duration: TimeInterval, name: String?, observations: [(Date, Double)]) {
            guard reset > now else { return }
            if used >= 100 { gaps.append((now, reset, name)); return }
            let horizon = reset.timeIntervalSince(latest.date)
            let elapsed = duration - horizon
            let initialRate: Double? = elapsed.isFinite && elapsed >= minimumObservationSpan && elapsed <= duration ? used / elapsed : nil
            guard let long = rate(observations, minutes: 60) ?? initialRate else { return }
            let short = rate(observations, minutes: 10) ?? long
            // Any shortfall counts. Use the faster pace for both warnings and spare.
            let burn = max(short, long)
            guard used > 0 || burn > 0 else { return }
            // Remove floating-point roundoff at exact thresholds, not real shortfalls.
            let spare = ((100 - used - burn * horizon) * 1e9).rounded() / 1e9
            if name == nil { sessionSpare = spare }
            if spare < 0, burn > 0 {
                gaps.append((max(now, latest.date.addingTimeInterval((100 - used) / burn)), reset, name))
            }
        }

        if let reset = latest.reset {
            let observations = counterObservations(samples.map { ($0.date, $0.used, $0.reset) })
            evaluate(used: latest.used, reset: reset, duration: 5 * 3600, name: nil, observations: observations)
        }
        for window in latest.weekly ?? [] {
            var counters: [(Date, Double, Date?)] = []
            for sample in samples {
                guard let previous = sample.weekly?.first(where: { $0.id == window.id }) else {
                    counters.removeAll()
                    continue
                }
                counters.append((sample.date, previous.used, previous.reset))
            }
            evaluate(used: window.used, reset: window.reset, duration: 7 * 86400, name: window.name, observations: counterObservations(counters))
        }
        if var gap = gaps.sorted(by: { $0.0 < $1.0 }).first {
            for other in gaps.sorted(by: { $0.0 < $1.0 }) where other.0 <= gap.1 {
                if other.1 > gap.1 { gap.1 = other.1; gap.2 = other.2 }
            }
            return gap.0 <= now ? .out(gap.1, gap.2) : .gap(gap.0, gap.1, gap.2)
        }
        guard let reset = latest.reset else { return .ready }
        guard reset > now else { return .awaitingUpdate }
        if latest.used == 0 && sessionSpare == nil { return .ready }
        guard let spare = sessionSpare else { return .estimating }
        if spare >= 10 { return .spare(Int(floor(spare / 5)) * 5, reset) }
        return .onTrack
    }

    var isGap: Bool {
        switch self { case .gap, .out: return true; default: return false }
    }

    func title(now: Date = Date(), locale: Locale = .current) -> String {
        switch self {
        case .estimating: return "Measuring"
        case .awaitingUpdate: return "Waiting for usage"
        case .stale: return "No data"
        case .ready: return "Ready"
        case .onTrack: return "On track"
        case let .spare(percent, reset): return "\(percent)% spare till \(Clock.time(Clock.displayReset(reset), locale: locale))"
        case let .out(reset, name):
            let reset = Clock.displayReset(reset)
            let day = name != nil && !Calendar.current.isDate(reset, inSameDayAs: now)
            return "\(name.map { $0 + " out" } ?? "Out") till \(Clock.time(reset, day: day, period: name != nil, locale: locale))"
        case let .gap(start, reset, name):
            let reset = Clock.displayReset(reset)
            let rounded = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / 300) * 300)
            let day = name != nil && !Calendar.current.isDate(reset, inSameDayAs: now)
            let startDay = name != nil && !Calendar.current.isDate(rounded, inSameDayAs: now)
            return "\(name.map { $0 + " out" } ?? "Out") \(Clock.time(rounded, day: startDay, period: name != nil, locale: locale))–\(Clock.time(reset, day: day, period: name != nil, locale: locale))"
        }
    }

    var accessibilityText: String {
        switch self {
        case .awaitingUpdate: return "The previous quota window has ended. Waiting for updated Claude usage."
        case let .gap(start, reset, name): return "\(name ?? "Claude") quota is predicted to run out at \(start.formatted()). Resets at \(Clock.displayReset(reset).formatted())."
        case let .out(reset, name): return "\(name ?? "Claude") quota is out until \(Clock.displayReset(reset).formatted())."
        case let .spare(percent, reset): return "An estimated \(percent) percent of Claude quota will remain unused at reset, \(Clock.displayReset(reset).formatted())."
        default: return "Claude usage forecast: \(title())."
        }
    }
}

struct History: Codable {
    var samples: [UsageSample] = []

    mutating func record(_ sample: UsageSample) {
        if let last = samples.last, sample.date <= last.date { samples.removeAll() }
        samples.append(sample)
        retainRecentSuffix()
    }

    mutating func retainRecentSuffix() {
        guard let latest = samples.last else { return }
        let cutoff = latest.date.addingTimeInterval(-3600)
        var first = max(0, samples.count - 256)
        while first + 2 < samples.count && samples[first + 1].date < cutoff { first += 1 }
        if first > 0 { samples.removeFirst(first) }
    }
}
