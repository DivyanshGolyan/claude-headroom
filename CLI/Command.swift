import Foundation
import Darwin

enum HeadroomCLI {
    static let help = """
    Usage: headroom <status|refresh> [--format json|text] [--timeout 30s]

    status   Read the running app's current state without fetching usage.
    refresh  Wait for a refresh, joining an existing request when possible.

    JSON is the default format. The app must already be running.
    --timeout limits the total wait in seconds (default: 30s; maximum: 300s).
    A timeout does not cancel a shared refresh in the app.

    Exit codes: 0 success, 1 operation failed, 2 invalid arguments.
    """

    struct Output {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static func run(_ arguments: [String], path: String = LocalSocket.path) -> Output {
        if arguments == ["--help"] || arguments == ["-h"] ||
            (arguments.count == 2 && ["status", "refresh"].contains(arguments[0]) && arguments[1] == "--help") {
            return Output(stdout: help + "\n", stderr: "", exitCode: 0)
        }
        var format = "json"
        var timeout: Double = 30
        let operation: HeadroomRequest.Operation
        do {
            guard let first = arguments.first, let parsed = HeadroomRequest.Operation(rawValue: first) else {
                throw invalid("Expected status or refresh. Use headroom --help for usage.")
            }
            operation = parsed
            var index = 1
            var seen = Set<String>()
            while index < arguments.count {
                let option = arguments[index]
                guard ["--format", "--timeout"].contains(option), seen.insert(option).inserted,
                      index + 1 < arguments.count else { throw invalid("Unknown, repeated, or incomplete option: \(option).") }
                let value = arguments[index + 1]
                if option == "--format" {
                    guard ["json", "text"].contains(value) else { throw invalid("Format must be json or text.") }
                    format = value
                } else {
                    let number = value.hasSuffix("s") ? String(value.dropLast()) : value
                    guard let seconds = Double(number), seconds.isFinite, seconds > 0, seconds <= 300 else {
                        throw invalid("Timeout must be greater than zero and at most 300 seconds.")
                    }
                    timeout = seconds
                }
                index += 2
            }
        } catch {
            return output(HeadroomResponse(data: nil, error: error as? HeadroomFailure), format: format, exitCode: 2)
        }

        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            let descriptor = try LocalSocket.connect(to: path, deadline: deadline)
            defer { close(descriptor) }
            try LocalSocket.write(HeadroomJSON.encode(HeadroomRequest(operation)), to: descriptor, deadline: deadline)
            let data = try LocalSocket.read(descriptor, deadline: deadline)
            let response: HeadroomResponse
            do { response = try HeadroomJSON.decode(HeadroomResponse.self, from: data) }
            catch { throw HeadroomFailure(code: "protocol_mismatch", message: "Headroom returned an incompatible response. Update the app and CLI together.") }
            guard response.schema_version == HeadroomRequest.version, response.data != nil || response.error != nil else {
                throw HeadroomFailure(code: "protocol_mismatch", message: "Headroom returned an incompatible response. Update the app and CLI together.")
            }
            return output(response, format: format, exitCode: response.error == nil ? 0 : 1)
        } catch {
            let failure = (error as? HeadroomFailure) ?? LocalSocket.failure("Could not communicate with Headroom.")
            return output(HeadroomResponse(data: nil, error: failure), format: format, exitCode: 1)
        }
    }

    private static func invalid(_ message: String) -> HeadroomFailure {
        HeadroomFailure(code: "invalid_arguments", message: message)
    }

    private static func output(_ response: HeadroomResponse, format: String, exitCode: Int32) -> Output {
        if format == "json" {
            do {
                let data = try HeadroomJSON.encode(response)
                return Output(stdout: String(decoding: data, as: UTF8.self) + "\n", stderr: "", exitCode: exitCode)
            } catch {
                return Output(stdout: "{\"schema_version\":1,\"data\":null,\"error\":{\"code\":\"encoding_error\",\"message\":\"Cannot encode Headroom status.\"}}\n", stderr: "", exitCode: 1)
            }
        }
        var lines: [String] = []
        if let status = response.data {
            lines.append(status.forecast.kind.rawValue.replacingOccurrences(of: "_", with: " "))
            if let start = status.forecast.starts_at { lines.append("Starts: \(date(start))") }
            if let end = status.forecast.ends_at { lines.append("Ends: \(date(end))") }
            if let spare = status.forecast.estimated_spare_percent { lines.append("Estimated spare: \(spare)%") }
            if let reason = status.forecast.reason { lines.append("Reason: \(reason)") }
            if let observation = status.observation {
                let age = observation.age_seconds.map { "\(Int($0))s old" } ?? "age unknown"
                lines.append("Observation: \(observation.freshness.rawValue), \(age)")
                for quota in observation.quotas {
                    lines.append("\(quota.kind): \(quota.used_percent)% used" + (quota.resets_at.map { ", resets \(date($0))" } ?? ", no active window"))
                }
            } else { lines.append("No observation yet.") }
            if let failure = status.update.last_error { lines.append("Last update: \(failure.code): \(failure.message)") }
            if let retry = status.update.retry_after_seconds { lines.append("Retry after: \(Int(ceil(retry)))s") }
        }
        let diagnostic = response.error.map { "\($0.code): \($0.message)\n" } ?? ""
        return Output(stdout: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n", stderr: diagnostic, exitCode: exitCode)
    }

    private static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
}
