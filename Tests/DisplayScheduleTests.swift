import Foundation

@main enum DisplayScheduleTests {
    static func main() {
        let start = ContinuousClock.now
        let date = UsageResponse.parseDate("2026-10-12T12:00:00Z")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        func instant(_ seconds: Double) -> ContinuousClock.Instant { start.advanced(by: .seconds(seconds)) }
        func at(_ seconds: Double) -> Date { date.addingTimeInterval(seconds) }
        func expectDate(_ actual: Date?, _ expected: Date) {
            precondition(actual != nil && abs(actual!.timeIntervalSince(expected)) < 0.00001)
        }
        func expectDeadline(_ display: RuntimeTimeline.Display, _ seconds: Double) {
            precondition(display.nextUpdate != nil)
            precondition(abs(start.duration(to: display.nextUpdate!).timeInterval - seconds) < 0.00001)
        }
        func timeline(_ sample: UsageSample) -> RuntimeTimeline {
            var result = RuntimeTimeline()
            result.record(FetchedUsage(sample: sample, receivedAt: start, serverDate: date))
            return result
        }
        let ready = UsageSample(date: date, used: 0, reset: at(7200))
        let live = timeline(ready)
        func display(_ seconds: Double) -> RuntimeTimeline.Display {
            live.display(at: instant(seconds), wallNow: at(seconds), calendar: utc)
        }
        precondition(display(0).forecast == .ready)
        expectDeadline(display(0), 360.001)
        expectDeadline(display(360), 360.001)
        precondition(!StatusPresentation(forecast: display(360).forecast, now: at(360), age: live.age(at: instant(360)), problem: nil, retryAt: nil).appearsDisabled)
        precondition(StatusPresentation(forecast: display(360.001).forecast, now: at(360.001), age: live.age(at: instant(360.001)), problem: nil, retryAt: nil).appearsDisabled)
        expectDeadline(display(360.001), 900.001)
        precondition(display(900).forecast == .ready)
        expectDeadline(display(900), 900.001)
        precondition(display(900.001).forecast == .stale)
        expectDeadline(display(900.001), 7200)
        precondition(display(8000).forecast == .stale)
        expectDeadline(display(8000), 43200)
        for (used, horizon, expected): (Double, Double, Forecast) in [
            (50, 9000, .onTrack),
            (20, 9000, .spare(60, at(9000))),
            (1, 18000, .estimating)
        ] {
            let sample = UsageSample(date: date, used: used, reset: at(horizon))
            let steady = timeline(sample)
            let initial = steady.display(at: start, wallNow: date, calendar: utc)
            precondition(initial.forecast == expected)
            expectDeadline(initial, 360.001)
            precondition(steady.display(at: instant(300), wallNow: at(300), calendar: utc).forecast == expected)
        }
        print("PASS no minute polling; inclusive dim/freshness boundaries and sleep-sized jumps")

        let reset = at(600)
        let weekly = [QuotaWindow(id: "weekly", used: 100, reset: reset, name: "Weekly")]
        let hidden = [UsageSample(date: at(-60), used: 80, reset: reset, weekly: weekly),
                      UsageSample(date: date, used: 90, reset: reset, weekly: weekly)]
        let projection = Forecast.project(samples: hidden, now: date)
        precondition(projection.forecast == .out(reset, "Weekly"))
        expectDate(projection.nextChange, at(60))
        precondition(Forecast.calculate(samples: hidden, now: at(59.999)) == .out(reset, "Weekly"))
        precondition(Forecast.calculate(samples: hidden, now: at(60)) == .out(reset))
        expectDate(Forecast.project(samples: hidden, now: at(60)).nextChange, reset)
        precondition(Forecast.calculate(samples: hidden, now: reset) == .awaitingUpdate)
        let session = hidden.map { UsageSample(date: $0.date, used: $0.used, reset: $0.reset) }
        precondition(Forecast.calculate(samples: session, now: date) == .gap(at(60), reset))
        expectDate(Forecast.project(samples: session, now: date).nextChange, at(60))
        precondition(Forecast.calculate(samples: session, now: at(60)) == .likelyOut(reset))
        let overlap = UsageSample(date: date, used: 100, reset: at(100), weekly: [
            QuotaWindow(id: "weekly", used: 100, reset: at(200), name: "Weekly")])
        expectDate(Forecast.project(samples: [overlap], now: date).nextChange, at(100))
        expectDate(Forecast.project(samples: [overlap], now: at(100)).nextChange, at(200))
        precondition(Forecast.calculate(samples: [overlap], now: at(200)) == .awaitingUpdate)
        print("PASS exhaustion and every overlapping reset, including hidden equal-end attribution")

        let future = Forecast.project(samples: [ready], now: at(-1))
        precondition(future.forecast == .stale)
        expectDate(future.nextChange, date)
        precondition(Forecast.project(samples: [], now: date).nextChange == nil)
        let short = UsageSample(date: date, used: 0, reset: at(1000))
        let stale = timeline(short)
        expectDeadline(stale.display(at: instant(950), wallNow: at(950), calendar: utc), 1000)
        precondition(StatusPresentation.usageDetail(sample: short, now: at(999.999)) != StatusPresentation.usageDetail(sample: short, now: at(1000)))
        let restored = RuntimeTimeline(restored: History(samples: [short]))
        precondition(restored.calendarNow(at: instant(8000)) == date)
        let frozen = restored.display(at: instant(8000), wallNow: at(8000), calendar: utc)
        precondition(frozen.forecast == .stale)
        expectDeadline(frozen, 43200)
        let empty = RuntimeTimeline().display(at: start, wallNow: date, calendar: utc)
        precondition(empty.forecast == .estimating)
        expectDeadline(empty, 43200)
        print("PASS stale tooltip reset, future samples, empty state and frozen restored history")

        expectDeadline(live.display(at: start, wallNow: at(43100), calendar: utc), 100)
        expectDeadline(live.display(at: start, wallNow: at(-86400), calendar: utc), 360.001)
        var nearMidnight = RuntimeTimeline()
        nearMidnight.record(FetchedUsage(sample: ready, receivedAt: start, serverDate: at(43100)))
        expectDeadline(nearMidnight.display(at: start, wallNow: date, calendar: utc), 100)
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (text, length) in [("2026-03-08T08:00:00Z", 23.0 * 3600), ("2026-11-01T07:00:00Z", 25.0 * 3600)] {
            let midnight = UsageResponse.parseDate(text)!
            expectDeadline(RuntimeTimeline().display(at: start, wallNow: midnight, calendar: losAngeles), length)
        }
        print("PASS independent wall/server midnights, wall jumps and 23/25-hour DST days")
    }
}
