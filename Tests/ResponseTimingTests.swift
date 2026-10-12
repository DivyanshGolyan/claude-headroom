import Foundation

@main enum ResponseTimingTests {
    static func main() throws {
        let start = ContinuousClock.now
        for elapsed: Duration in [.zero, .seconds(1), .seconds(25)] {
            try ResponseTiming.validate(startedAt: start, receivedAt: start.advanced(by: elapsed))
        }
        for elapsed: Duration in [.seconds(25) + .nanoseconds(1), .seconds(60), .seconds(3600)] {
            do {
                try ResponseTiming.validate(startedAt: start, receivedAt: start.advanced(by: elapsed))
                preconditionFailure("A suspended response cannot acquire a fresh receipt timestamp")
            } catch let error as URLError {
                precondition(error.code == .timedOut)
            }
        }
        print("PASS response acceptance includes the resource-budget boundary and rejects elapsed suspension")

        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = wall.addingTimeInterval(7200)
        for wallShift in [-86400.0, 0, 86400] {
            var timeline = RuntimeTimeline()
            timeline.record(FetchedUsage(sample: UsageSample(date: wall, used: 20, reset: reset),
                receivedAt: start, serverDate: wall))
            let resumed = start.advanced(by: .seconds(3600))
            do {
                try ResponseTiming.validate(startedAt: start.advanced(by: .seconds(59)), receivedAt: resumed)
                timeline.record(FetchedUsage(sample: UsageSample(date: wall.addingTimeInterval(wallShift), used: 21, reset: reset),
                    receivedAt: resumed, serverDate: wall.addingTimeInterval(60)))
                preconditionFailure("A suspended response cannot enter forecast history")
            } catch let error as URLError {
                precondition(error.code == .timedOut)
            }
            precondition(timeline.age(at: resumed) == 3600)
            precondition(timeline.calendarNow(at: resumed) == wall.addingTimeInterval(3600))
            precondition(timeline.forecast(at: resumed) == .stale)
            precondition(timeline.history.samples.count == 1)
            precondition(timeline.history.samples.last?.reset == reset)
            try ResponseTiming.validate(startedAt: resumed, receivedAt: resumed.advanced(by: .seconds(1)))
        }
        print("PASS suspended responses cannot rewind the calendar or refresh stale data; the next request succeeds")

        let receipt = start.advanced(by: .seconds(1))
        let delivered = start.advanced(by: .seconds(3600))
        try ResponseTiming.validate(startedAt: start, receivedAt: receipt)
        var delayedTimeline = RuntimeTimeline()
        delayedTimeline.record(FetchedUsage(sample: UsageSample(date: wall, used: 20, reset: reset),
            receivedAt: receipt, serverDate: wall))
        precondition(delayedTimeline.age(at: delivered) == 3599)
        precondition(delayedTimeline.forecast(at: delivered) == .stale)
        var delayedGate = RefreshGate()
        delayedGate.finish(nextAttempt: receipt.advanced(by: .seconds(120)), rateLimitUntil: receipt.advanced(by: .seconds(120)))
        precondition(delayedGate.begin(at: delivered, manual: true))
        print("PASS delayed UI delivery retains original sample age and cannot extend a receipt-anchored cooldown")
    }
}
