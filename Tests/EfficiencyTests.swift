import Foundation

@main enum EfficiencyTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let instant = ContinuousClock.now
        var gate = RefreshGate()
        precondition(gate.begin(at: instant))
        precondition(!gate.begin(at: instant.advanced(by: .seconds(60)), manual: true), "In-flight fetches must not overlap")
        gate.finish(nextAttempt: instant.advanced(by: .seconds(300)))
        precondition(gate.earliestManualAttempt(at: instant) == instant.advanced(by: .seconds(15)), "Login completion bypasses ordinary backoff but retains request spacing")
        precondition(!gate.begin(at: instant.advanced(by: .seconds(14)), manual: true), "Manual refresh must respect minimum cadence")
        precondition(!gate.begin(at: instant.advanced(by: .seconds(15))), "Timer must respect failure backoff")
        precondition(gate.begin(at: instant.advanced(by: .seconds(15)), manual: true), "Manual refresh may retry a non-429 failure")
        gate.finish(nextAttempt: instant.advanced(by: .seconds(900)), rateLimitUntil: instant.advanced(by: .seconds(900)))
        precondition(gate.earliestManualAttempt(at: instant.advanced(by: .seconds(30))) == instant.advanced(by: .seconds(900)), "Login completion retains the server cooldown")
        precondition(!gate.allowsManual(at: instant.advanced(by: .seconds(899))))
        precondition(!gate.begin(at: instant.advanced(by: .seconds(899)), manual: true), "Manual refresh cannot bypass 429")
        precondition(gate.begin(at: instant.advanced(by: .seconds(900))))
        gate.finish()
        precondition(!gate.begin(at: instant.advanced(by: .seconds(914))), "Timer and wake share the manual refresh cadence")
        precondition(gate.begin(at: instant.advanced(by: .seconds(915))))
        print("PASS timer, wake and manual refresh share bounded cadence, overlap and 429 protection")

        let reset = now.addingTimeInterval(3600)
        let samples = (0..<400).map { index in
            UsageSample(date: now.addingTimeInterval(Double(index - 399) * 2), used: index < 390 ? 80 : 10, reset: reset)
        }
        var history = History(samples: samples)
        history.retainRecentSuffix()
        precondition(history.samples.count == 256)
        precondition(history.samples.map(\.date) == samples.suffix(256).map(\.date), "Bounded history must be contiguous")
        precondition(Forecast.calculate(samples: history.samples, now: now) == .spare(85, reset), "Cap must discard the old rate and use the corrected window total")
        history.record(UsageSample(date: now.addingTimeInterval(1), used: 11, reset: reset))
        precondition(history.samples.count == 256 && history.samples.first!.date == samples[145].date)
        history.record(UsageSample(date: now.addingTimeInterval(7200), used: 12, reset: reset))
        precondition(history.samples.count == 2, "Sparse history keeps one interpolation anchor")
        history.record(UsageSample(date: now, used: 1, reset: reset))
        precondition(history.samples.count == 1, "Non-increasing timestamps still reset history")
        print("PASS history stays bounded without hiding corrections or losing sparse anchors")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-store-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Headroom/history.json")
        let store = HistoryStore(url: url)
        try store.save(History(samples: samples))
        precondition(store.load()!.samples.count == 256, "Existing oversized history normalizes on load")
        func permissions(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
        }
        precondition((try? permissions(url)) == 0o600)
        precondition((try? permissions(url.deletingLastPathComponent())) == 0o700)
        try store.save(history)
        precondition(store.load()!.samples.last!.used == 1)
        precondition((try? permissions(url)) == 0o600)
        precondition((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) == ["history.json"], "Atomic replacement must clean temporary files")
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try store.save(history)
        precondition(store.load()!.samples.count == 1 && (try? permissions(url)) == 0o600)
        try Data(repeating: 0, count: 256 * 1024 + 1).write(to: url)
        precondition(store.load() == nil, "Oversized cache must be rejected before decoding")
        try store.save(history)
        precondition(store.load()!.samples.count == 1, "Oversized cache must not prevent future checkpoints")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do {
            try store.save(history)
            preconditionFailure("Replacing a directory must fail")
        } catch {}
        precondition((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) == ["history.json"], "Failed replacements must clean private temporary files")
        try FileManager.default.removeItem(at: url)
        try store.save(history)
        precondition(store.load()!.samples.count == 1, "Write failure must not disable future checkpoints")
        print("PASS private atomic checkpoints replace cleanly and recover from directory deletion")

        let savedZone = NSTimeZone.default
        defer { NSTimeZone.default = savedZone; Clock.invalidate() }
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        let date = UsageResponse.parseDate("2026-10-12T13:50:00Z")!
        precondition(Clock.time(date, locale: Locale(identifier: "en_US")) == "1:50")
        precondition(Clock.time(date, locale: Locale(identifier: "en_GB")) == "13:50")
        NSTimeZone.default = TimeZone(identifier: "Asia/Kolkata")!
        precondition(Clock.time(date, locale: Locale(identifier: "en_GB")) == "19:20")
        precondition(Clock.time(date, period: true, locale: Locale(identifier: "en_US")).contains("PM"))
        precondition(!Clock.time(date, period: false, locale: Locale(identifier: "en_US")).contains("PM"))
        Clock.invalidate()
        precondition(Clock.time(date, locale: Locale(identifier: "en_US")) == "7:20")
        for identifier in ["en_US@hours=h23", "en_US@hours=h12", "en_GB", "en_US"] {
            let locale = Locale(identifier: identifier)
            for day in [false, true] {
                for period in [false, true] {
                    let reference = DateFormatter()
                    reference.locale = locale
                    reference.timeZone = NSTimeZone.default
                    let format = DateFormatter.dateFormat(fromTemplate: day ? "EEEjmm" : "jmm", options: 0, locale: locale)!
                    reference.dateFormat = period ? format : format.replacingOccurrences(of: "\\s*[abB]\\s*", with: "", options: .regularExpression)
                    precondition(Clock.time(date, day: day, period: period, locale: locale) == reference.string(from: date).trimmingCharacters(in: .whitespaces), "Cached clock must honor resolved hour preference")
                }
            }
        }
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            precondition(UsageResponse.parseDate("2026-10-12T13:50:00.123Z") != nil)
            precondition(Clock.time(date, locale: Locale(identifier: "en_US")) == "7:20")
        }
        print("PASS cached date formats preserve locale, zone, period and concurrent access")
    }
}
