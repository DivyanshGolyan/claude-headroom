import Foundation

struct RefreshGate {
    private(set) var busy = false
    private(set) var nextAttempt = Date.distantPast
    private(set) var rateLimitUntil = Date.distantPast
    private var earliestStart = Date.distantPast

    func allowsManual(at now: Date) -> Bool {
        !busy && now >= earliestStart && now >= rateLimitUntil
    }

    mutating func begin(at now: Date, manual: Bool = false) -> Bool {
        guard allowsManual(at: now), manual || now >= nextAttempt else { return false }
        busy = true
        earliestStart = now.addingTimeInterval(15)
        return true
    }

    mutating func finish(nextAttempt: Date = .distantPast, rateLimitUntil: Date = .distantPast) {
        busy = false
        self.nextAttempt = nextAttempt
        self.rateLimitUntil = rateLimitUntil
    }
}
