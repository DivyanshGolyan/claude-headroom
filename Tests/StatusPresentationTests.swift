import Foundation

@main
enum StatusPresentationTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let retry = now.addingTimeInterval(240)
        for age in [0.0, 181, 601, .infinity] {
            for forecast in [Forecast.onTrack, .stale, .gap(now, retry)] {
                let status = StatusPresentation(forecast: forecast, now: now, age: age,
                    problem: .rateLimited, retryAt: retry)
                precondition(status.title == "Rate limited · retry \(Clock.time(retry))")
                precondition(status.accessibilityText.contains(retry.formatted(date: .omitted, time: .standard)))
                precondition(!status.showsForecast && !status.appearsDisabled)
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
        print("PASS fetch failures expose their cause and scheduled retry; recovery restores the forecast")
    }
}
