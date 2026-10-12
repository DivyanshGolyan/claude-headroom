import Foundation

struct RefreshGate {
    private(set) var busy = false
    private(set) var nextAttempt: ContinuousClock.Instant?
    private(set) var rateLimitUntil: ContinuousClock.Instant?
    private var earliestStart: ContinuousClock.Instant?

    func earliestManualAttempt(at now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        max(now, earliestStart ?? now, rateLimitUntil ?? now)
    }

    func allowsManual(at now: ContinuousClock.Instant) -> Bool {
        !busy && (earliestStart.map { now >= $0 } ?? true)
            && (rateLimitUntil.map { now >= $0 } ?? true)
    }

    mutating func begin(at now: ContinuousClock.Instant, manual: Bool = false) -> Bool {
        guard allowsManual(at: now), manual || nextAttempt.map({ now >= $0 }) ?? true else { return false }
        busy = true
        earliestStart = now.advanced(by: .seconds(15))
        return true
    }

    mutating func finish(nextAttempt: ContinuousClock.Instant? = nil, rateLimitUntil: ContinuousClock.Instant? = nil) {
        busy = false
        self.nextAttempt = nextAttempt
        self.rateLimitUntil = rateLimitUntil
    }

    func nextAttemptDate(at now: ContinuousClock.Instant, wallNow: Date) -> Date? {
        nextAttempt.map { wallNow.addingTimeInterval(max(0, now.duration(to: $0).timeInterval)) }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
