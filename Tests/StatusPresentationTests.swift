import Foundation

@main
enum StatusPresentationTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let retry = now.addingTimeInterval(240)
        for age in [901.0, .infinity] {
            for forecast in [Forecast.onTrack, .stale, .gap(now, retry)] {
                let status = StatusPresentation(forecast: forecast, now: now, age: age,
                    problem: .rateLimited, retryAt: retry)
                precondition(status.title == "Rate limited · retry \(Clock.deadline(retry, relativeTo: now))")
                precondition(status.accessibilityText.contains(Clock.deadline(retry, relativeTo: now, seconds: true)))
                precondition(!status.showsForecast && !status.appearsDisabled)
            }
        }
        for age in [0.0, 180, 181, 601, 900] {
            for forecast in [Forecast.ready, .onTrack, .spare(20, retry), .gap(now, retry), .out(retry)] {
                for problem in [FetchProblem.rateLimited, .unavailable] {
                    let status = StatusPresentation(forecast: forecast, now: now, age: age,
                        problem: problem, retryAt: retry)
                    precondition(status.title == forecast.title(now: now), "usable forecasts survive temporary fetch failures")
                    precondition(status.showsForecast && status.appearsDisabled == (age > 180))
                    if problem == .rateLimited {
                        precondition(status.accessibilityText.contains("rate limited"))
                        precondition(status.accessibilityText.contains(Clock.deadline(retry, relativeTo: now, seconds: true)))
                    }
                }
            }
        }
        for forecast in [Forecast.stale, .estimating, .awaitingReset] {
            for age in [0.0, 180, 900] {
                for problem in [FetchProblem.rateLimited, .unavailable] {
                    let status = StatusPresentation(forecast: forecast, now: now, age: age,
                        problem: problem, retryAt: retry)
                    precondition(!status.showsForecast && !status.appearsDisabled)
                    precondition(problem == .rateLimited ? status.title.hasPrefix("Rate limited") : status.title == "Usage unavailable")
                }
            }
        }
        let missingDeadline = StatusPresentation(forecast: .stale, now: now, age: .infinity,
            problem: .rateLimited, retryAt: nil)
        precondition(missingDeadline.title == "Rate limited")
        let recovered = StatusPresentation(forecast: .onTrack, now: now, age: 0, problem: nil, retryAt: nil)
        precondition(recovered.title == "On track" && recovered.showsForecast)
        let signedOut = StatusPresentation(forecast: .stale, now: now, age: .infinity, problem: .signedOut, retryAt: retry)
        precondition(signedOut.title == "Signed out" && !signedOut.showsForecast)
        let unavailable = StatusPresentation(forecast: .stale, now: now, age: .infinity, problem: .unavailable, retryAt: retry)
        precondition(unavailable.title == "Usage unavailable" && !unavailable.showsForecast)
        let transient = StatusPresentation(forecast: .onTrack, now: now, age: 181, problem: .unavailable, retryAt: retry)
        precondition(transient.title == "On track" && transient.appearsDisabled)
        let iso = ISO8601DateFormatter()
        let reference = iso.date(from: "2026-10-12T11:55:00Z")!
        let zone = TimeZone(secondsFromGMT: 0)!
        let noon = iso.date(from: "2026-10-12T18:00:00Z")!
        let tomorrow = iso.date(from: "2026-10-13T18:00:00Z")!
        let distant = iso.date(from: "2050-10-13T18:00:00Z")!
        let twelveHour = Locale(identifier: "en_US@hours=h12")
        let twentyFourHour = Locale(identifier: "en_GB@hours=h23")
        let afternoon = Clock.deadline(noon, relativeTo: reference, locale: twelveHour, timeZone: zone)
        precondition(afternoon.contains("6:00") && afternoon.uppercased().contains("PM"))
        for seconds in [false, true] {
            let nextDay = Clock.deadline(tomorrow, relativeTo: reference, seconds: seconds, locale: twelveHour, timeZone: zone)
            precondition(nextDay.contains("13") && nextDay.contains("Oct") && nextDay.uppercased().contains("PM"))
            let nextYear = Clock.deadline(distant, relativeTo: reference, seconds: seconds, locale: twelveHour, timeZone: zone)
            precondition(nextYear.contains("2050"))
            let military = Clock.deadline(tomorrow, relativeTo: reference, seconds: seconds, locale: twentyFourHour, timeZone: zone)
            precondition(military.contains("18:00") && !military.uppercased().contains("PM"))
        }
        print("PASS retry deadlines disambiguate noon, next-day, distant-year and 12/24-hour formats")
        print("PASS fetch failures expose their cause and scheduled retry; recovery restores the forecast")
    }
}
