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
        switch problem {
        case .signedOut:
            title = "Signed out"
            accessibilityText = "Claude is signed out. Sign into Claude Code."
            showsForecast = false
        case .rateLimited:
            title = "Rate limited" + (retryAt.map { " · retry \(Clock.time($0))" } ?? "")
            accessibilityText = "Claude usage updates are rate limited." + (retryAt.map {
                " Next automatic attempt is \($0.formatted(date: .omitted, time: .standard))."
            } ?? "")
            showsForecast = false
        case .unavailable where age > 600:
            title = "Usage unavailable"
            accessibilityText = "Claude usage data is unavailable."
            showsForecast = false
        default:
            title = forecast.title(now: now)
            accessibilityText = forecast.accessibilityText
            showsForecast = true
        }
        appearsDisabled = showsForecast && age > 180 && age <= 600
    }
}
