import Foundation
import Darwin

@MainActor
final class ControlledUsage {
    private(set) var calls = 0
    private var pending: CheckedContinuation<FetchedUsage, Error>?

    func fetch() async throws -> FetchedUsage {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func complete(_ result: Result<FetchedUsage, Error>) {
        precondition(pending != nil)
        let continuation = pending!
        pending = nil
        continuation.resume(with: result)
    }
}

@main enum HeadroomTests {
    @MainActor static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            precondition(ContinuousClock.now < deadline, "Timed out waiting for test state")
            await Task.yield()
        }
    }

    static func response(_ output: HeadroomCLI.Output) throws -> HeadroomResponse {
        precondition(output.stderr.isEmpty)
        precondition(output.stdout.filter { $0 == "\n" }.count == 1, "Exactly one JSON line")
        return try HeadroomJSON.decode(HeadroomResponse.self, from: Data(output.stdout.utf8))
    }

    @MainActor static func main() async throws {
        let directory = "/tmp/headroom-test-\(UUID().uuidString)"
        try LocalSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = HistoryStore(url: URL(fileURLWithPath: directory + "/history.json"))
        let usage = ControlledUsage()
        let engine = HeadroomEngine(historyStore: store, fetch: { try await usage.fetch() })
        precondition(engine.status().api.observation == nil)
        precondition(engine.status().api.forecast.kind == .measuring)
        precondition(usage.calls == 0, "A status read never fetches")

        let first = Task { await engine.refresh() }
        await until { usage.calls == 1 }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await engine.refresh()
        }
        await until { secondStarted }
        precondition(engine.status().api.update.in_progress)
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let receipt = ContinuousClock.now
        let sample = UsageSample(date: wall, used: 60, reset: wall.addingTimeInterval(3600),
            weekly: [.init(id: "upstream-weekly-opus", used: 30, reset: wall.addingTimeInterval(86400), name: "Opus")])
        usage.complete(.success(FetchedUsage(sample: sample, receivedAt: receipt, serverDate: wall)))
        let firstResult = await first.value
        let secondResult = await second.value
        precondition(firstResult.error == nil && secondResult.error == nil)
        precondition(usage.calls == 1, "Concurrent refreshes join the same request")
        precondition(firstResult.status.sample?.used == secondResult.status.sample?.used)
        precondition(engine.status().api.observation?.quotas.map(\.kind) == ["five_hour", "seven_day_opus"])
        precondition(engine.status().api.observation?.freshness == .fresh)
        precondition(engine.status(at: receipt.advanced(by: .seconds(361))).api.observation?.freshness == .aging)
        let old = engine.status(at: receipt.advanced(by: .seconds(901)))
        precondition(old.api.forecast.kind == .unavailable && old.api.observation?.freshness == .stale)
        let shifted = engine.status(at: receipt.advanced(by: .seconds(74)), wallNow: wall.addingTimeInterval(86400))
        precondition(shifted.api.observation?.age_seconds == 74, "Wall-clock changes cannot change age")
        precondition(shifted.presentation.title == StatusPresentation(forecast: shifted.forecast,
            now: shifted.wallNow, age: shifted.age, problem: nil, retryAt: shifted.retryAt).title)
        let restored = HeadroomEngine(historyStore: store, fetch: { preconditionFailure("Restored status must not fetch") })
        let restoredStatus = restored.status().api
        precondition(restoredStatus.observation?.freshness == .unknown)
        precondition(restoredStatus.observation?.age_seconds == nil && restoredStatus.forecast.kind == .unavailable)
        let restoredJSON = try JSONSerialization.jsonObject(with: HeadroomJSON.encode(restoredStatus)) as! [String: Any]
        precondition((restoredJSON["observation"] as! [String: Any])["age_seconds"] is NSNull)
        print("PASS shared refresh, side-effect-free status, clock-safe freshness, restored data and public quota categories")

        var burstSamples = [
            FetchedUsage(sample: UsageSample(date: wall.addingTimeInterval(-300), used: 60, reset: sample.reset),
                receivedAt: receipt.advanced(by: .seconds(-300)), serverDate: wall.addingTimeInterval(-300)),
            FetchedUsage(sample: UsageSample(date: wall, used: 80, reset: sample.reset), receivedAt: receipt, serverDate: wall)
        ]
        let burstEngine = HeadroomEngine(historyStore: HistoryStore(url: URL(fileURLWithPath: directory + "/burst.json")),
            fetch: { burstSamples.removeFirst() })
        _ = await burstEngine.refresh()
        _ = await burstEngine.refresh()
        precondition(burstEngine.status(at: receipt).api.forecast.kind == .predicted_outage,
            "The shared engine must preserve rolling observations rather than estimate from only the latest sample")
        let expectedExhaustion = wall.addingTimeInterval(300)
        precondition(burstEngine.status(at: receipt).api.forecast.starts_at == expectedExhaustion)
        precondition(burstEngine.status(at: receipt.advanced(by: .seconds(301))).api.forecast.kind == .likely_outage)
        let exhausted = HeadroomEngine(historyStore: HistoryStore(url: URL(fileURLWithPath: directory + "/out.json")), fetch: {
            FetchedUsage(sample: UsageSample(date: wall, used: 100, reset: sample.reset), receivedAt: receipt, serverDate: wall)
        })
        _ = await exhausted.refresh()
        precondition(exhausted.status(at: receipt).api.forecast.kind == .outage)
        print("PASS rolling consumption rate, precise exhaustion timestamp and predicted versus confirmed exhaustion")

        let failed = Task { await engine.refresh() }
        await until { usage.calls == 2 }
        usage.complete(.failure(UsageError.message("Synthetic outage")))
        let failedResult = await failed.value
        precondition(failedResult.error?.code == "usage_unavailable")
        precondition(failedResult.status.api.forecast.kind != .unavailable, "Transient failure retains a usable forecast")
        precondition(failedResult.status.api.observation?.quotas.first?.used_percent == 60)

        let signedOut = Task { await engine.refresh() }
        await until { usage.calls == 3 }
        usage.complete(.failure(UsageError.signedOut))
        let signedOutResult = await signedOut.value
        precondition(signedOutResult.status.api.forecast.kind == .unavailable)
        precondition(signedOutResult.status.api.forecast.reason == "signed_out")
        precondition(signedOutResult.status.api.observation?.freshness == .fresh)

        let limited = Task { await engine.refresh() }
        await until { usage.calls == 4 }
        usage.complete(.failure(UsageError.rateLimited(.seconds(120), receivedAt: .now)))
        let limitedResult = await limited.value
        precondition(limitedResult.error?.code == "rate_limited")
        precondition((limitedResult.error?.retry_after_seconds ?? 0) > 119)
        let blocked = await engine.refresh()
        precondition(blocked.error?.code == "rate_limited" && usage.calls == 4)
        engine.loginCompleted()
        engine.refreshIfDue()
        precondition(usage.calls == 4, "Login and wake cannot bypass the server cooldown")
        print("PASS transient errors, immediate auth suppression, explicit refresh failures and shared server cooldown")

        let path = directory + "/control.sock"
        let server = HeadroomServer(engine: engine)
        try server.start(path: path)
        defer { server.stop() }
        let duplicate = HeadroomServer(engine: engine)
        do {
            try duplicate.start(path: path)
            preconditionFailure("A second server cannot steal the endpoint")
        } catch let failure as HeadroomFailure { precondition(failure.code == "app_already_running") }
        let statusOutput = await Task.detached { HeadroomCLI.run(["status"], path: path) }.value
        let statusResponse = try response(statusOutput)
        precondition(statusOutput.exitCode == 0 && statusResponse.error == nil)
        precondition(statusResponse.data?.update.last_error?.code == "rate_limited")
        precondition(statusResponse.data?.observation?.quotas.first?.used_percent == 60)
        precondition(usage.calls == 4, "The real CLI status request never fetches")
        let refreshOutput = await Task.detached { HeadroomCLI.run(["refresh"], path: path) }.value
        let refreshResponse = try response(refreshOutput)
        precondition(refreshOutput.exitCode == 1 && refreshResponse.error?.code == "rate_limited")
        precondition(refreshResponse.data != nil, "A failed refresh labels retained data with an error")
        precondition(usage.calls == 4)
        let text = await Task.detached { HeadroomCLI.run(["status", "--format", "text"], path: path) }.value
        precondition(text.exitCode == 0 && text.stdout.contains("five_hour: 60.0% used"))

        let protocolMismatch = try await Task.detached {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            let socket = try LocalSocket.connect(to: path, deadline: deadline)
            defer { close(socket) }
            try LocalSocket.write(HeadroomJSON.encode(HeadroomRequest(.status, version: 99)), to: socket, deadline: deadline)
            return try HeadroomJSON.decode(HeadroomResponse.self, from: LocalSocket.read(socket, deadline: deadline))
        }.value
        precondition(protocolMismatch.error?.code == "protocol_mismatch")
        let malformed = try await Task.detached {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            let socket = try LocalSocket.connect(to: path, deadline: deadline)
            defer { close(socket) }
            try LocalSocket.write(Data("{\"operation\":\"delete\"}".utf8), to: socket, deadline: deadline)
            return try HeadroomJSON.decode(HeadroomResponse.self, from: LocalSocket.read(socket, deadline: deadline))
        }.value
        precondition(malformed.error?.code == "invalid_request")
        print("PASS CLI over real local sockets, JSON/text output, failed refresh status, duplicate owner and protocol validation")

        let stalePath = directory + "/stale.sock"
        let staleSocket = try LocalSocket.make()
        var staleAddress = try LocalSocket.address(stalePath)
        let bound = withUnsafePointer(to: &staleAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(staleSocket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0)
        close(staleSocket)
        let recovered = HeadroomServer(engine: engine)
        try recovered.start(path: stalePath)
        defer { recovered.stop() }
        let recoveredOutput = await Task.detached { HeadroomCLI.run(["status"], path: stalePath) }.value
        precondition(recoveredOutput.exitCode == 0, "A stale socket cannot prevent restart")
        let unsafe = directory + "/unsafe"
        precondition(mkdir(unsafe, 0o755) == 0)
        precondition(chmod(unsafe, 0o755) == 0)
        do {
            try LocalSocket.prepareDirectory(unsafe)
            preconditionFailure("A shared directory cannot host the control socket")
        } catch let failure as HeadroomFailure { precondition(failure.code == "connection_error") }
        print("PASS stale endpoint recovery and private-directory enforcement")

        for arguments in [[], ["unknown"], ["status", "--force"], ["status", "--timeout", "nan"],
            ["refresh", "--timeout", "0"], ["status", "--format", "yaml"], ["status", "--format"],
            ["status", "--timeout", "1s", "--timeout", "2s"]] {
            let output = HeadroomCLI.run(arguments, path: directory + "/absent.sock")
            precondition(output.exitCode == 2)
            let error = try response(output).error
            precondition(error?.code == "invalid_arguments")
        }
        let absent = HeadroomCLI.run(["status"], path: directory + "/absent.sock")
        precondition(absent.exitCode == 1)
        let absentResponse = try response(absent)
        precondition(absentResponse.error?.code == "app_not_running")
        precondition(HeadroomCLI.run(["--help"]).exitCode == 0)
        print("PASS deterministic argument errors, exit codes, help and app-not-running behavior")

        let timeoutUsage = ControlledUsage()
        let timeoutEngine = HeadroomEngine(historyStore: HistoryStore(url: URL(fileURLWithPath: directory + "/other-history.json")),
            fetch: { try await timeoutUsage.fetch() })
        let timeoutServer = HeadroomServer(engine: timeoutEngine)
        let timeoutPath = directory + "/timeout.sock"
        try timeoutServer.start(path: timeoutPath)
        defer { timeoutServer.stop() }
        let timeoutClient = Task.detached { HeadroomCLI.run(["refresh", "--timeout", "0.2s"], path: timeoutPath) }
        await until { timeoutUsage.calls == 1 }
        let timeoutOutput = await timeoutClient.value
        let timeoutResponse = try response(timeoutOutput)
        precondition(timeoutOutput.exitCode == 1 && timeoutResponse.error?.code == "timeout")
        precondition(timeoutEngine.status().busy, "A CLI timeout must not cancel the shared fetch")
        timeoutUsage.complete(.success(FetchedUsage(sample: sample, receivedAt: .now, serverDate: wall)))
        await until { !timeoutEngine.status().busy }
        let joined = await Task.detached { HeadroomCLI.run(["status"], path: timeoutPath) }.value
        precondition(joined.exitCode == 0 && timeoutUsage.calls == 1)
        let joinedResponse = try response(joined)
        precondition(joinedResponse.data?.observation?.quotas.first?.used_percent == 60)
        print("PASS CLI timeout leaves the shared refresh alive and a later status reads its result")
    }
}
