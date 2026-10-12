import Foundation

actor UsageClient {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = ResponseTiming.maximumRequestDuration.timeInterval
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func fetch() async throws -> FetchedUsage {
        let token = try accessToken()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let startedAt = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        let receivedAt = ContinuousClock.now
        try ResponseTiming.validate(startedAt: startedAt, receivedAt: receivedAt)
        let localDate = Date()
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.message("Claude returned an invalid response.")
        }
        let serverDate = HTTPDate.parse(http.value(forHTTPHeaderField: "Date"))
        switch http.statusCode {
        case 200:
            return FetchedUsage(sample: try JSONDecoder().decode(UsageResponse.self, from: data).sample(at: localDate),
                receivedAt: receivedAt, serverDate: serverDate)
        case 401, 403: throw UsageError.signedOut
        case 429:
            throw UsageError.rateLimited(HTTPDate.retryDelay(http.value(forHTTPHeaderField: "Retry-After"),
                serverDate: serverDate, localDate: localDate), receivedAt: receivedAt)
        default: throw UsageError.message("Claude usage request failed (HTTP \(http.statusCode)).")
        }
    }

    private func accessToken() throws -> String {
        // Reuse the same Keychain reader as the existing headroom CLI.
        // The token stays in memory and is never written to the history or logs.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.signedOut
        }
        return token
    }
}
