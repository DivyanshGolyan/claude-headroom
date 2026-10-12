import Foundation

struct FetchedUsage {
    let sample: UsageSample
    let receivedAt: ContinuousClock.Instant
    let serverDate: Date?
}

struct RuntimeTimeline {
    private(set) var history: History
    private var anchor: (date: Date, instant: ContinuousClock.Instant, fromServer: Bool)?
    private var lastReceipt: ContinuousClock.Instant?

    init(restored: History = History()) {
        history = History(samples: Array(restored.samples.suffix(1)))
    }

    mutating func record(_ fetched: FetchedUsage) {
        let date = fetched.serverDate ?? fetched.sample.date
        let needsAnchor: Bool
        if let anchor {
            needsAnchor = fetched.serverDate.map {
                !anchor.fromServer || abs($0.timeIntervalSince(calendarNow(at: fetched.receivedAt))) > 30
            } ?? false
        } else {
            needsAnchor = true
        }
        if needsAnchor {
            history = History()
            anchor = (date, fetched.receivedAt, fetched.serverDate != nil)
        }
        let sample = fetched.sample
        history.record(UsageSample(date: calendarNow(at: fetched.receivedAt), used: sample.used,
            reset: sample.reset, weekly: sample.weekly))
        lastReceipt = fetched.receivedAt
    }

    func calendarNow(at now: ContinuousClock.Instant) -> Date {
        guard let anchor else { return history.samples.last?.date ?? .distantPast }
        return anchor.date.addingTimeInterval(anchor.instant.duration(to: now).timeInterval)
    }

    func age(at now: ContinuousClock.Instant) -> TimeInterval {
        lastReceipt.map { max(0, $0.duration(to: now).timeInterval) } ?? .infinity
    }

    func forecast(at now: ContinuousClock.Instant) -> Forecast {
        guard lastReceipt != nil else { return history.samples.isEmpty ? .estimating : .stale }
        return Forecast.calculate(samples: history.samples, now: calendarNow(at: now))
    }

    struct Display {
        let forecast: Forecast
        let nextUpdate: ContinuousClock.Instant?
    }

    func display(at instant: ContinuousClock.Instant, wallNow: Date,
        calendar: Calendar = .current) -> Display {
        var nextUpdate: ContinuousClock.Instant?
        func consider(_ delay: TimeInterval) {
            guard delay > 0 else { return }
            let deadline = instant.advanced(by: .seconds(delay))
            nextUpdate = nextUpdate.map { min($0, deadline) } ?? deadline
        }
        func midnight(after date: Date) {
            if let end = calendar.dateInterval(of: .day, for: date)?.end {
                consider(end.timeIntervalSince(date))
            }
        }
        midnight(after: wallNow)
        guard lastReceipt != nil else {
            return Display(forecast: history.samples.isEmpty ? .estimating : .stale, nextUpdate: nextUpdate)
        }
        let now = calendarNow(at: instant)
        let projection = Forecast.project(samples: history.samples, now: now)
        if let change = projection.nextChange { consider(change.timeIntervalSince(now)) }
        if age(at: instant) <= StatusPresentation.dimAfter {
            consider(StatusPresentation.dimAfter + Forecast.boundaryAllowance - age(at: instant))
        }
        // The tooltip changes at session reset even after the forecast becomes stale.
        if let reset = history.samples.last?.reset { consider(reset.timeIntervalSince(now)) }
        midnight(after: now)
        return Display(forecast: projection.forecast, nextUpdate: nextUpdate)
    }

    var snapshot: History { History(samples: Array(history.samples.suffix(1))) }
}
