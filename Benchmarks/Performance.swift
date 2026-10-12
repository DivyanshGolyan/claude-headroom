import AppKit
import Darwin

@main
struct Audit {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(7200)
        let samples = (0...60).map { i in UsageSample(date: now.addingTimeInterval(Double(i - 60) * 60), used: 10 + Double(i), reset: reset) }
        let forecast = Forecast.calculate(samples: samples, now: now)
        guard case .gap = forecast else { fatalError("Fixture must predict an outage") }
        let payload = Data("{\"five_hour\":{\"utilization\":70,\"resets_at\":\"2027-01-15T10:00:00.000Z\"},\"seven_day\":{\"utilization\":40,\"resets_at\":\"2027-01-20T10:00:00Z\"}}".utf8)
        var checksum = 0
        let count = 1000
        func measure(_ name: String, operation: () throws -> Int) rethrows {
            let start = clock()
            for _ in 0..<count { checksum &+= try autoreleasepool(invoking: operation) }
            let microseconds = Double(clock() - start) / Double(CLOCKS_PER_SEC) * 1_000_000 / Double(count)
            print("\(name) cpu_us_per_op=\(String(format: "%.2f", microseconds)) count=\(count)")
        }
        _ = forecast.title(now: now)
        _ = StatusStyle.width(forecast: forecast, title: forecast.title(now: now))
        _ = try JSONDecoder().decode(UsageResponse.self, from: payload).sample(at: now)
        for round in 1...5 {
            print("round=\(round)")
            measure("forecast_61_samples") { Forecast.calculate(samples: samples, now: now).isGap ? 1 : 0 }
            measure("gap_title_and_width") {
                let title = forecast.title(now: now)
                return title.utf8.count + Int(StatusStyle.width(forecast: forecast, title: title))
            }
            try measure("decode_two_windows") {
                let sample = try JSONDecoder().decode(UsageResponse.self, from: payload).sample(at: now)
                guard sample.used == 70, sample.weekly?.count == 1 else { fatalError("Decode failed") }
                return Int(sample.used)
            }
        }
        print("errors=0 checksum=\(checksum)")
    }
}
