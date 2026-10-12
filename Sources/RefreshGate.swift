import Foundation

struct RefreshGate {
    static let automaticInterval: Duration = .seconds(300)
    private(set) var busy = false
    private(set) var nextAttempt: ContinuousClock.Instant?
    private(set) var rateLimitUntil: ContinuousClock.Instant?

    func earliestManualAttempt(at now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        max(now, rateLimitUntil ?? now)
    }

    func allowsManual(at now: ContinuousClock.Instant) -> Bool {
        !busy && (rateLimitUntil.map { now >= $0 } ?? true)
    }

    mutating func begin(at now: ContinuousClock.Instant, manual: Bool = false) -> Bool {
        guard !busy else { return false }
        if manual {
            guard allowsManual(at: now) else { return false }
        } else {
            guard now >= earliestAutomaticAttempt(at: now) else { return false }
        }
        busy = true
        return true
    }

    mutating func finish(nextAttempt: ContinuousClock.Instant? = nil, rateLimitUntil: ContinuousClock.Instant? = nil) {
        busy = false
        self.nextAttempt = nextAttempt
        self.rateLimitUntil = rateLimitUntil
    }

    func earliestAutomaticAttempt(at now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        max(now, nextAttempt ?? now, rateLimitUntil ?? now)
    }

    func nextAttemptDate(at now: ContinuousClock.Instant, wallNow: Date) -> Date? {
        nextAttempt.map { _ in wallNow.addingTimeInterval(now.duration(to: earliestAutomaticAttempt(at: now)).timeInterval) }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
