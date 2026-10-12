import Foundation

enum FetchProblem {
    case signedOut, rateLimited, unavailable
}

struct StatusPresentation {
    let title: String
    let accessibilityText: String
    let showsForecast: Bool
    let appearsDisabled: Bool

    init(forecast: Forecast, now: Date, age: TimeInterval, problem: FetchProblem?, retryAt: Date?) {
        let canForecast = (0...Forecast.maximumSampleAge).contains(age) && forecast != .stale && forecast != .estimating
        let rateLimitDetail = problem == .rateLimited ? "Claude usage updates are rate limited." + (retryAt.map {
            " Next automatic attempt is \($0.formatted(date: .omitted, time: .standard))."
        } ?? "") : ""
        switch problem {
        case .signedOut:
            title = "Signed out"
            accessibilityText = "Claude is signed out. Sign into Claude Code."
            showsForecast = false
        case .rateLimited where !canForecast:
            title = "Rate limited" + (retryAt.map { " · retry \(Clock.time($0))" } ?? "")
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
        appearsDisabled = showsForecast && age > 180 && age <= Forecast.maximumSampleAge
    }
}
