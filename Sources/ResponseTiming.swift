import Foundation

enum ResponseTiming {
    static let maximumRequestDuration: Duration = .seconds(25)

    static func validate(startedAt: ContinuousClock.Instant, receivedAt: ContinuousClock.Instant) throws {
        guard startedAt.duration(to: receivedAt) <= maximumRequestDuration else {
            throw URLError(.timedOut)
        }
    }
}
