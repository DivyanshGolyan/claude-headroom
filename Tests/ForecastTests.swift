import Foundation

@main
enum ForecastTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3 * 3600)
        func sample(_ minutesAgo: Double, _ used: Double, reset date: Date? = nil) -> UsageSample {
            UsageSample(date: now.addingTimeInterval(-minutesAgo * 60), used: used, reset: date ?? reset)
        }
        func forecast(_ before: Double, _ after: Double, minutes: Double = 30, reset date: Date? = nil) -> Forecast {
            Forecast.calculate(samples: [sample(minutes, before, reset: date), sample(0, after, reset: date)], now: now)
        }
        func expect(_ condition: Bool, _ name: String) {
            precondition(condition, "FAILED: \(name)")
            print("PASS \(name)")
        }

        expect(Forecast.calculate(samples: [], now: now) == .estimating, "no history does not invent a rate")
        expect(forecast(20, 21, minutes: 4) == .estimating, "five-minute warm-up")
        expect(forecast(35, 40) == .spare(30, reset), "projects spare from measured consumption")
        expect(forecast(45, 50) == .spare(20, reset), "20 percent spare")
        expect(forecast(55, 60) == .spare(10, reset), "10 percent is spare")
        expect(forecast(56, 61) == .onTrack, "9 percent spare is on track")
        expect(forecast(65, 70) == .onTrack, "exact exhaustion at reset is on track")
        expect(forecast(65.001, 70.001) != .onTrack, "even a sub-minute gap is a gap")
        if case let .gap(start, end, _) = forecast(50, 60) {
            expect(abs(start.timeIntervalSince(now) - 7200) < 0.01 && end == reset, "exhaustion and reset timestamps")
        } else { preconditionFailure("Expected gap") }
        expect(forecast(20, 20) == .spare(80, reset), "idle time counts as zero consumption")
        expect(forecast(100, 100) == .out(reset), "already exhausted needs no warm-up")
        expect(forecast(20, 30, reset: now) == .awaitingReset, "expired quota is never reused")
        expect(Forecast.calculate(samples: [sample(11, 30)], now: now) == .stale, "stale measurements are marked")

        let oldReset = reset.addingTimeInterval(-5 * 3600)
        expect(Forecast.calculate(samples: [sample(30, 90, reset: oldReset), sample(0, 10)], now: now) == .estimating, "separate quota windows")
        let recent = [sample(40, 0), sample(20, 20), sample(0, 20)]
        // Baseline at -30m is 10%, so the last 30m rate is 10% / 30m.
        expect(abs(Forecast.rate(recent.map { ($0.date, $0.used) }, minutes: 30)! - 10.0 / 1800) < 0.000001, "interpolates a lookback cutoff")

        var history = History()
        history.record(sample(10, 20))
        history.record(sample(0, 21))
        expect(history.samples.count == 2, "missed samples preserve cumulative observations")
        history.record(UsageSample(date: now.addingTimeInterval(60), used: 5, reset: reset))
        expect(history.samples.count == 3, "history preserves corrections for per-window filtering")
        history.record(UsageSample(date: now.addingTimeInterval(120), used: 6, reset: reset.addingTimeInterval(5 * 3600)))
        expect(history.samples.count == 4, "history keeps independent weekly observations across session resets")
        let decoded = try JSONDecoder().decode(History.self, from: JSONEncoder().encode(history))
        expect(decoded.samples.count == 4 && decoded.samples.last!.used == 6, "local history survives relaunch")

        var jitter = History()
        jitter.record(sample(1, 20))
        jitter.record(sample(0, 21, reset: reset.addingTimeInterval(2)))
        expect(jitter.samples.count == 2, "server reset timestamp jitter preserves history")

        NSTimeZone.default = TimeZone(identifier: "Asia/Kolkata")!
        let gapStart = UsageResponse.parseDate("2026-10-12T13:05:00Z")!
        let gapEnd = UsageResponse.parseDate("2026-10-12T13:50:00Z")!
        expect(Forecast.gap(gapStart, gapEnd).title(now: gapStart, locale: Locale(identifier: "en_US")) == "Out 6:35–7:20", "agreed gap label")
        expect(Forecast.spare(18, gapEnd).title(now: gapStart, locale: Locale(identifier: "en_US")) == "18% spare till 7:20", "agreed spare label")
        expect(Forecast.onTrack.title() == "On track", "agreed on-track label")

        for (offset, minute) in [(-0.477, "7:20"), (0.0, "7:20"), (0.383, "7:20"), (30.0, "7:21")] {
            let jittered = gapEnd.addingTimeInterval(offset)
            expect(Forecast.gap(gapStart, jittered).title(now: gapStart, locale: Locale(identifier: "en_US")) == "Out 6:35–\(minute)", "reset display rounds to the nearest minute")
            expect(Forecast.out(jittered).title(now: gapStart, locale: Locale(identifier: "en_US")) == "Out till \(minute)", "current outage reset display rounds to nearest minute")
            expect(Forecast.spare(20, jittered).title(now: gapStart, locale: Locale(identifier: "en_US")) == "20% spare till \(minute)", "spare reset display rounds to nearest minute")
            let precise = Forecast.calculate(samples: [UsageSample(date: gapStart, used: 100, reset: jittered)], now: gapStart)
            expect(precise == .out(jittered), "display rounding preserves precise forecast reset")
        }

        let midnightReset = UsageResponse.parseDate("2026-10-12T18:29:59.523Z")!
        let midnightLabel = Forecast.out(midnightReset, "Weekly").title(now: gapStart, locale: Locale(identifier: "en_US"))
        expect(midnightLabel.contains("Tue") && midnightLabel.contains("12:00"), "weekly reset rounding includes the next weekday at midnight")

        let json = Data("{\"five_hour\":{\"utilization\":37,\"resets_at\":\"2026-10-12T13:49:59.537793+00:00\"},\"limits\":[]}".utf8)
        expect(try JSONDecoder().decode(UsageResponse.self, from: json).sample(at: now).used == 37, "actual endpoint schema with fractional reset timestamp")
        expect(UsageResponse.parseDate("2026-10-12T13:49:59Z") != nil, "non-fractional reset timestamp")
        do {
            _ = try JSONDecoder().decode(UsageResponse.self, from: Data("{\"five_hour\":null}".utf8)).sample(at: now)
            expect(Forecast.calculate(samples: [try JSONDecoder().decode(UsageResponse.self, from: Data("{\"five_hour\":null}".utf8)).sample(at: now)], now: now) == .ready, "inactive window is calm")
        } catch { preconditionFailure("Inactive window must decode") }
        let burst = [sample(60, 0), sample(10, 0), sample(0, 20)]
        if case let .gap(start, _, _) = Forecast.calculate(samples: burst, now: now) {
            expect(abs(start.timeIntervalSince(now) - 2400) < 0.01, "short rate catches a burst hidden by the long average")
        } else { preconditionFailure("Burst must warn immediately") }
        expect(forecast(50, 55) == .spare(15, reset), "spare rounds down in five-percent steps")
        expect(forecast(56, 61) == .onTrack, "spare below ten never remains latched")
        expect(forecast(70, 71, minutes: 40, reset: now.addingTimeInterval(900)) == .spare(25, now.addingTimeInterval(900)), "short horizon uses the minimum fifteen-minute baseline")
        let correction = [sample(30, 90), sample(1, 10), sample(0, 11)]
        expect(Forecast.calculate(samples: correction, now: now) == .estimating, "counter correction requires fresh observations")
        expect(Forecast.calculate(samples: [sample(10, 10), sample(0, 12)], now: now) != .estimating, "missed observations preserve measured usage")
        let oldWindow = [sample(10, 80, reset: oldReset), sample(0, 5)]
        expect(Forecast.calculate(samples: oldWindow, now: now) == .estimating, "session reset never borrows the previous window rate")
        expect(Forecast.gap(gapStart.addingTimeInterval(120), gapEnd).title(now: gapStart, locale: Locale(identifier: "en_US")) == "Out 6:35–7:20", "run-out time rounds down to five minutes")
        expect(Forecast.out(gapEnd).title(now: gapStart, locale: Locale(identifier: "en_US")) == "Out till 7:20", "current exhaustion differs from future exhaustion")
        expect(Forecast.gap(gapStart, gapEnd).title(now: gapStart, locale: Locale(identifier: "en_GB")) == "Out 18:35–19:20", "24-hour locale is preserved")
        expect(Forecast.gap(gapStart, gapEnd).accessibilityText.contains("predicted"), "VoiceOver receives a full forecast sentence")
        let weekReset = now.addingTimeInterval(2 * 86400)
        let week = QuotaWindow(id: "weekly", used: 100, reset: weekReset, name: "Weekly")
        expect(Forecast.calculate(samples: [UsageSample(date: now, used: 5, reset: reset, weekly: [week])], now: now) == .out(weekReset, "Weekly"), "exhausted weekly quota overrides session warm-up")
        let weekBefore = QuotaWindow(id: "weekly", used: 80, reset: weekReset, name: "Weekly")
        let weekAfter = QuotaWindow(id: "weekly", used: 90, reset: weekReset, name: "Weekly")
        let weeklyBurst = [UsageSample(date: now.addingTimeInterval(-600), used: 5, reset: reset, weekly: [weekBefore]), UsageSample(date: now, used: 5, reset: reset, weekly: [weekAfter])]
        if case let .gap(start, end, name) = Forecast.calculate(samples: weeklyBurst, now: now) {
            expect(abs(start.timeIntervalSince(now) - 600) < 0.01 && end == weekReset && name == "Weekly", "weekly burn can be the limiting window")
        } else { preconditionFailure("Expected weekly gap") }
        var overlap = weeklyBurst
        overlap[1] = UsageSample(date: now, used: 100, reset: reset, weekly: [weekAfter])
        expect(Forecast.calculate(samples: overlap, now: now) == .out(weekReset, "Weekly"), "overlapping limits extend the continuous outage to the later reset")
        let weeklyJSON = Data("{\"five_hour\":null,\"limits\":[{\"kind\":\"weekly\",\"percent\":100,\"resets_at\":\"2027-10-12T13:50:00Z\",\"is_active\":true},{\"kind\":\"weekly_scoped\",\"percent\":100,\"resets_at\":\"2027-10-12T13:50:00Z\",\"is_active\":false,\"scope\":{\"model\":{\"display_name\":\"Fable\"}}}]}".utf8)
        expect(try JSONDecoder().decode(UsageResponse.self, from: weeklyJSON).sample(at: now).weekly?.count == 1, "inactive unrelated model limit is excluded")
        do {
            _ = try JSONDecoder().decode(UsageResponse.self, from: Data("{}".utf8))
            preconditionFailure("Schema change must fail")
        } catch { print("PASS missing field is distinct from an explicitly inactive window") }
        let legacy = Data("{\"samples\":[{\"date\":1,\"used\":45,\"reset\":1000}]}".utf8)
        expect(try JSONDecoder().decode(History.self, from: legacy).samples.count == 1, "existing installed history remains readable")
        print("All forecast checks passed.")
    }
}
