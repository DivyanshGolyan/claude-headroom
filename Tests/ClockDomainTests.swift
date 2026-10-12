import Foundation

@main enum ClockDomainTests {
    static func main() {
        let start = ContinuousClock.now
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = wall.addingTimeInterval(7200)
        func instant(_ seconds: Int) -> ContinuousClock.Instant { start.advanced(by: .seconds(seconds)) }
        func fetched(_ seconds: Int, used: Double, local: Date, server: Date? = nil) -> FetchedUsage {
            FetchedUsage(sample: UsageSample(date: local, used: used, reset: reset), receivedAt: instant(seconds), serverDate: server)
        }
        for shift in [-86400.0, 0, 86400] {
            var gate = RefreshGate()
            precondition(gate.begin(at: start))
            gate.finish(nextAttempt: instant(300))
            precondition(!gate.begin(at: instant(299)))
            precondition(gate.nextAttemptDate(at: instant(100), wallNow: wall.addingTimeInterval(shift)) == wall.addingTimeInterval(shift + 200))
            precondition(gate.begin(at: instant(300)))
            gate.finish(nextAttempt: instant(600))
            precondition(!gate.begin(at: instant(599)))
            precondition(gate.begin(at: instant(600)))
            gate.finish(nextAttempt: instant(900), rateLimitUntil: instant(900))
            precondition(!gate.begin(at: instant(899), manual: true))
            precondition(gate.begin(at: instant(900), manual: true))
            gate.finish()
            precondition(!gate.begin(at: instant(914), manual: true))
            precondition(gate.begin(at: instant(915), manual: true))
            gate.finish()
            precondition(gate.begin(at: instant(7200)), "Sleep-sized elapsed advance must expire cooldowns without consulting wall time")

            var timeline = RuntimeTimeline()
            for minute in 0...60 {
                timeline.record(fetched(minute * 60, used: 20 + Double(minute) / 2,
                    local: wall.addingTimeInterval(Double(minute * 60) + (minute == 0 ? 0 : shift))))
            }
            precondition(timeline.history.samples.count == 61)
            precondition(timeline.history.samples.first!.date == wall)
            precondition(timeline.history.samples.last!.date == wall.addingTimeInterval(3600))
            precondition(timeline.calendarNow(at: instant(3600)) == wall.addingTimeInterval(3600))
            precondition(timeline.forecast(at: instant(3600)) == .spare(20, reset))
            precondition(timeline.age(at: instant(3780)) == 180)
            precondition(timeline.age(at: instant(3781)) > 180)
            precondition(timeline.forecast(at: instant(4200)) != .stale)
            precondition(timeline.forecast(at: instant(4500)) != .stale)
            precondition(timeline.forecast(at: instant(4501)) == .stale)
            timeline.record(fetched(7200, used: 60, local: wall))
            precondition(timeline.history.samples.count == 3, "Sleep includes elapsed time and retention keeps an interpolation anchor")
            precondition(timeline.history.samples.last!.reset == reset, "Raw reset timestamp must never be shifted")
            var bursting = RuntimeTimeline()
            for minute in 0...60 {
                bursting.record(fetched(minute * 60, used: 20 + Double(minute),
                    local: wall.addingTimeInterval(Double(minute * 60) + (minute == 0 ? 0 : shift))))
            }
            precondition(bursting.forecast(at: instant(3600)) == .gap(wall.addingTimeInterval(4800), reset))
        }
        print("PASS cadence, retry deadlines, 429, freshness, forecast and retention ignore wall jumps and include sleep")

        let server = HTTPDate.parse("Mon, 12 Oct 2026 12:00:00 GMT")!
        for shift in [-86400.0, 86400] {
            precondition(HTTPDate.retryDelay("Mon, 12 Oct 2026 12:05:00 GMT", serverDate: server, localDate: server.addingTimeInterval(shift)) == .seconds(300))
            precondition(HTTPDate.retryDelay("120", serverDate: nil, localDate: server.addingTimeInterval(shift)) == .seconds(120))
        }
        precondition(HTTPDate.retryDelay("Mon, 12 Oct 2026 12:05:00 GMT", serverDate: nil, localDate: server) == .seconds(300))
        precondition(HTTPDate.retryDelay("0", serverDate: server, localDate: wall) == .seconds(60))
        precondition(HTTPDate.retryDelay("Mon, 12 Oct 2026 11:00:00 GMT", serverDate: server, localDate: wall) == .seconds(60))
        for invalid: String? in [nil, "", "NaN", "inf", "-1", "1.5", "1e5", "garbage", "Mon, 99 Oct 2026 12:00:00 GMT", String(repeating: "9", count: 400)] {
            precondition(HTTPDate.retryDelay(invalid, serverDate: server, localDate: wall) == .seconds(300))
        }
        let huge = HTTPDate.retryDelay(String(repeating: "9", count: 200), serverDate: server, localDate: wall)
        precondition(huge == .seconds(300), "Unrepresentable finite cooldowns are invalid, not lifetime lockouts")
        let largest = HTTPDate.retryDelay(String(Int32.max), serverDate: server, localDate: wall)
        precondition(largest == .seconds(Int32.max))
        let hugeDeadline = start.advanced(by: largest)
        precondition(hugeDeadline > start, "Finite malicious cooldowns must remain representable as native deadlines")
        precondition(HTTPDate.parse("Mon, 12 Oct 2026 12:00:00 GMT trailing") == nil)
        precondition(HTTPDate.retryDelay("Fri, 31 Dec 9999 23:59:59 GMT", serverDate: server, localDate: wall) == .seconds(300))
        let delayedError = UsageError.rateLimited(.seconds(120), receivedAt: start)
        if case let .rateLimited(delay, receipt) = delayedError {
            precondition(receipt.advanced(by: delay) == instant(120), "MainActor delay cannot re-anchor a server cooldown")
        } else { preconditionFailure() }
        print("PASS HTTP retry durations use receipt and server time, validate finite numeric values, and fall back safely")

        var serverTimeline = RuntimeTimeline()
        serverTimeline.record(fetched(0, used: 20, local: wall.addingTimeInterval(90000), server: wall))
        for minute in 1...5 {
            serverTimeline.record(fetched(minute * 60, used: 20 + Double(minute), local: .distantPast,
                server: wall.addingTimeInterval(Double(minute * 60) + (minute.isMultiple(of: 2) ? 2 : -2))))
        }
        precondition(serverTimeline.history.samples.count == 6)
        precondition(serverTimeline.history.samples.last!.date == wall.addingTimeInterval(300), "Server jitter must not alter rates")
        precondition(serverTimeline.forecast(at: instant(300)) != .estimating)
        serverTimeline.record(fetched(360, used: 26, local: wall, server: wall.addingTimeInterval(391)))
        precondition(serverTimeline.history.samples.count == 1)
        precondition(serverTimeline.forecast(at: instant(360)) == .spare(55, reset))
        precondition(serverTimeline.history.samples.last!.reset == reset)
        var upgraded = RuntimeTimeline()
        upgraded.record(fetched(0, used: 20, local: wall))
        upgraded.record(fetched(300, used: 25, local: wall.addingTimeInterval(300)))
        upgraded.record(fetched(360, used: 26, local: wall, server: wall.addingTimeInterval(361)))
        precondition(upgraded.history.samples.count == 1, "First trusted server anchor starts a fresh observation window")
        precondition(upgraded.calendarNow(at: instant(360)) == wall.addingTimeInterval(361))
        print("PASS stable server anchors resist jitter; material discrepancy and first server anchor restart observations")

        for offset in [-90000.0, 90000] {
            let cached = History(samples: [UsageSample(date: wall.addingTimeInterval(offset - 300), used: 10, reset: reset),
                UsageSample(date: wall.addingTimeInterval(offset), used: 99, reset: reset)])
            var restored = RuntimeTimeline(restored: cached)
            precondition(restored.history.samples.count == 1)
            precondition(restored.forecast(at: start) == .stale)
            precondition(restored.age(at: start) == .infinity)
            restored.record(fetched(0, used: 50, local: wall))
            precondition(restored.history.samples.count == 1)
            precondition(restored.forecast(at: start) == .spare(15, reset))
            precondition(restored.snapshot.samples.count == 1)
            restored.record(fetched(60, used: 55, local: wall.addingTimeInterval(offset)))
            precondition(restored.forecast(at: instant(60)) != .estimating)
            precondition(restored.snapshot.samples.count == 1)
        }
        precondition(RuntimeTimeline().forecast(at: start) == .estimating)
        print("PASS restored past/future cache is stale display-only data and cannot supply rates or freshness")
    }
}
