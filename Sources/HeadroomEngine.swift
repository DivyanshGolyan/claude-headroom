import Foundation

struct MonitoringSnapshot {
    let sample: UsageSample?
    let forecast: Forecast
    let age: TimeInterval
    let calendarNow: Date
    let wallNow: Date
    let nextDisplayUpdate: ContinuousClock.Instant?
    let retryAt: Date?
    let retryAfter: TimeInterval?
    let busy: Bool
    let canRefresh: Bool
    let problem: FetchProblem?
    let failure: HeadroomFailure?

    var presentation: StatusPresentation {
        StatusPresentation(forecast: forecast, now: wallNow, age: age, problem: problem, retryAt: retryAt)
    }

    var api: HeadroomStatus {
        let observation = sample.map { sample in
            HeadroomStatus.Observation(observed_at: sample.date, age_seconds: age.isFinite ? age : nil,
                freshness: !age.isFinite ? .unknown : age > Forecast.maximumSampleAge ? .stale
                    : age > StatusPresentation.dimAfter ? .aging : .fresh,
                quotas: [.init(kind: "five_hour", used_percent: sample.used, resets_at: sample.reset)]
                    + (sample.weekly ?? []).map {
                        .init(kind: $0.name == "Opus" ? "seven_day_opus" : "seven_day",
                            used_percent: $0.used, resets_at: $0.reset)
                    })
        }
        let prediction: HeadroomStatus.Prediction
        if !presentation.showsForecast {
            prediction = .init(kind: .unavailable, reason: failure?.code ?? "stale")
        } else {
            switch forecast {
            case .estimating: prediction = .init(kind: .measuring)
            case .awaitingUpdate: prediction = .init(kind: .waiting_for_usage)
            case .stale: prediction = .init(kind: .unavailable, reason: "stale")
            case .ready: prediction = .init(kind: .ready)
            case .onTrack: prediction = .init(kind: .on_track)
            case let .spare(percent, reset):
                prediction = .init(kind: .spare, ends_at: reset, estimated_spare_percent: percent)
            case let .gap(start, end, _): prediction = .init(kind: .predicted_outage, starts_at: start, ends_at: end)
            case let .out(end, _): prediction = .init(kind: .outage, ends_at: end)
            case let .likelyOut(end, _): prediction = .init(kind: .likely_outage, ends_at: end)
            }
        }
        return HeadroomStatus(observation: observation, forecast: prediction,
            update: .init(in_progress: busy, last_error: failure, retry_after_seconds: retryAfter))
    }
}

@MainActor
final class HeadroomEngine {
    struct RefreshResult {
        let status: MonitoringSnapshot
        let error: HeadroomFailure?
    }

    var onChange: (() -> Void)?
    private let fetchUsage: () async throws -> FetchedUsage
    private let historyStore: HistoryStore
    private var timeline: RuntimeTimeline
    private var gate = RefreshGate()
    private var failures = 0
    private var problem: FetchProblem?
    private var failure: HeadroomFailure?
    private var loginRefreshPending = false
    private var fetchTimer: Timer?
    private var request: Task<RefreshResult, Never>?

    init(historyStore: HistoryStore, fetch: @escaping () async throws -> FetchedUsage) {
        self.historyStore = historyStore
        self.fetchUsage = fetch
        self.timeline = RuntimeTimeline(restored: historyStore.load() ?? History())
    }

    convenience init() {
        let client = UsageClient()
        self.init(historyStore: HistoryStore(url: FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Headroom/history.json")), fetch: { try await client.fetch() })
    }

    func status(at instant: ContinuousClock.Instant = .now, wallNow: Date = Date()) -> MonitoringSnapshot {
        let display = timeline.display(at: instant, wallNow: wallNow)
        let retryAfter = gate.rateLimitUntil.map { max(0, instant.duration(to: $0).timeInterval) }.flatMap { $0 > 0 ? $0 : nil }
        var currentFailure = failure
        currentFailure?.retry_after_seconds = retryAfter
        return MonitoringSnapshot(sample: timeline.history.samples.last, forecast: display.forecast,
            age: timeline.age(at: instant), calendarNow: timeline.calendarNow(at: instant), wallNow: wallNow,
            nextDisplayUpdate: display.nextUpdate, retryAt: gate.nextAttemptDate(at: instant, wallNow: wallNow),
            retryAfter: retryAfter, busy: gate.busy, canRefresh: gate.allowsManual(at: instant),
            problem: problem, failure: currentFailure)
    }

    func refresh() async -> RefreshResult {
        if let request { return await request.value }
        guard let request = begin(manual: true) else {
            let snapshot = status()
            return RefreshResult(status: snapshot, error: HeadroomFailure(code: "rate_limited",
                message: "Claude asked Headroom to wait before refreshing.", retry_after_seconds: snapshot.retryAfter))
        }
        return await request.value
    }

    func refreshIfDue() {
        if begin(manual: loginRefreshPending) == nil {
            onChange?()
            scheduleRefresh()
        }
    }

    func loginCompleted() {
        failures = 0
        loginRefreshPending = true
        scheduleRefresh()
    }

    private func begin(manual: Bool) -> Task<RefreshResult, Never>? {
        guard gate.begin(at: .now, manual: manual) else { return nil }
        loginRefreshPending = false
        fetchTimer?.invalidate()
        fetchTimer = nil
        let task = Task { await performFetch() }
        request = task
        onChange?()
        return task
    }

    private func performFetch() async -> RefreshResult {
        var nextAttempt: ContinuousClock.Instant
        var rateLimitUntil: ContinuousClock.Instant?
        do {
            let fetched = try await fetchUsage()
            timeline.record(fetched)
            failures = 0
            nextAttempt = fetched.receivedAt.advanced(by: RefreshGate.automaticInterval)
            problem = nil
            failure = nil
            try? historyStore.save(timeline.snapshot)
        } catch {
            failures += 1
            let backoff = Duration.seconds(min(900, 60 * pow(2, Double(min(failures - 1, 4)))))
            nextAttempt = ContinuousClock.now.advanced(by: backoff)
            switch error {
            case UsageError.signedOut:
                problem = .signedOut
                failure = HeadroomFailure(code: "signed_out", message: "The Claude credential is missing or was rejected. Run claude auth login, then refresh.")
                nextAttempt = ContinuousClock.now.advanced(by: .seconds(300))
            case let UsageError.rateLimited(delay, receivedAt):
                problem = .rateLimited
                failure = HeadroomFailure(code: "rate_limited", message: "Claude asked Headroom to wait. Refresh now also respects this cooldown.")
                nextAttempt = receivedAt.advanced(by: delay ?? backoff)
                rateLimitUntil = nextAttempt
            default:
                problem = .unavailable
                let message = (error as? UsageError).flatMap {
                    if case let .message(message) = $0 { return message }
                    return nil
                } ?? "Could not fetch Claude usage. Headroom will retry automatically."
                failure = HeadroomFailure(code: "usage_unavailable", message: message)
            }
        }
        gate.finish(nextAttempt: nextAttempt, rateLimitUntil: rateLimitUntil)
        request = nil
        let snapshot = status()
        onChange?()
        scheduleRefresh()
        return RefreshResult(status: snapshot, error: snapshot.failure)
    }

    private func scheduleRefresh() {
        guard !gate.busy else { return }
        let now = ContinuousClock.now
        let deadline = loginRefreshPending ? gate.earliestManualAttempt(at: now) : gate.earliestAutomaticAttempt(at: now)
        fetchTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, now.duration(to: deadline).timeInterval), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshIfDue() }
        }
    }
}
