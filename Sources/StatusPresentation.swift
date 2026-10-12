import Foundation

enum FetchProblem {
    case signedOut, rateLimited, unavailable
}

struct StatusPresentation {
    static let dimAfter: TimeInterval = 6 * 60
    let title: String
    let accessibilityText: String
    let showsForecast: Bool
    let appearsDisabled: Bool

    init(forecast: Forecast, now: Date, age: TimeInterval, problem: FetchProblem?, retryAt: Date?) {
        let hasCurrentWindow: Bool
        switch forecast {
        case .ready, .onTrack, .gap, .out, .likelyOut, .spare:
            hasCurrentWindow = true
        case .estimating, .awaitingUpdate, .stale:
            hasCurrentWindow = false
        }
        let canForecast = hasCurrentWindow && (0...Forecast.maximumSampleAge).contains(age)
        let rateLimitDetail = problem == .rateLimited ? "Claude usage updates are rate limited." + (retryAt.map {
            " Next automatic attempt is \(Clock.deadline($0, relativeTo: now, seconds: true))."
        } ?? "") : ""
        switch problem {
        case .signedOut:
            title = "Sign-in needed"
            accessibilityText = "Headroom needs a valid Claude credential. Choose Sign in to Claude from the menu."
            showsForecast = false
        case .rateLimited where !canForecast:
            title = "Rate limited" + (retryAt.map { " · retry \(Clock.deadline($0, relativeTo: now))" } ?? "")
            accessibilityText = rateLimitDetail
            showsForecast = false
        case .unavailable where !canForecast:
            title = "Usage unavailable"
            accessibilityText = "Claude usage data is unavailable."
            showsForecast = false
        default:
            title = forecast.title(now: now)
            accessibilityText = forecast.accessibilityText + (rateLimitDetail.isEmpty ? "" : " " + rateLimitDetail)
            showsForecast = true
        }
        appearsDisabled = showsForecast && age > Self.dimAfter && age <= Forecast.maximumSampleAge
    }

    static func usageDetail(sample: UsageSample?, now: Date) -> String {
        guard let sample else { return "Waiting for usage data" }
        guard let reset = sample.reset else { return "No active five-hour window" }
        if reset <= now {
            return "Previous window · \(Int(sample.used))% used · reset \(Clock.deadline(Clock.displayReset(reset), relativeTo: now))"
        }
        return "\(Int(sample.used))% used · resets \(Clock.time(Clock.displayReset(reset)))"
    }
}
