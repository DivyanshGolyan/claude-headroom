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

    var snapshot: History { History(samples: Array(history.samples.suffix(1))) }
}
