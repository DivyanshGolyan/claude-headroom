import Foundation

@main
enum SignInFlowTests {
    static func main() throws {
        if let completion = SignInFlow.completion(arguments: CommandLine.arguments) {
            SignInFlow.postCompletion(completion)
            return
        }
        let id = UUID().uuidString
        precondition(SignInFlow.completion(arguments: ["Headroom", "--login-completed", id])?.attemptID == id)
        precondition(SignInFlow.completion(arguments: ["Headroom", "--login-failed", id])?.succeeded == false)
        for args in [["Headroom"], ["Headroom", "--login-completed"],
                     ["Headroom", "--login-completed", "invalid"],
                     ["Headroom", "--login-completed", id, "extra"]] {
            precondition(SignInFlow.completion(arguments: args) == nil)
        }
        for olderSucceedsFirst in [true, false] {
            var attempts = SignInAttempts()
            let older = attempts.begin()
            let newer = attempts.begin()
            let success = SignInFlow.Completion(attemptID: older, succeeded: true)
            let cancellation = SignInFlow.Completion(attemptID: newer, succeeded: false)
            if olderSucceedsFirst {
                precondition(attempts.finish(success))
                precondition(!attempts.finish(cancellation))
            } else {
                precondition(!attempts.finish(cancellation))
                precondition(attempts.finish(success))
            }
            precondition(attempts.outstanding.isEmpty)
            precondition(!attempts.finish(success), "duplicate completion cannot trigger another fetch")
            precondition(!attempts.finish(.init(attemptID: UUID().uuidString, succeeded: true)))
        }
        print("PASS overlapping login attempts retain every success and retire failures in either completion order")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Headroom sign-in's test-\(id)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("fake cli")
        let callback = root.appendingPathComponent("fake Headroom")
        try "#!/bin/sh\nexit \"$HEADROOM_TEST_EXIT\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HEADROOM_TEST_RESULT\"\n".write(to: callback, atomically: true, encoding: .utf8)
        for file in [cli, callback] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        for exitCode in [0, 1, 130] {
            let directory = root.appendingPathComponent("attempt-\(exitCode)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = directory.appendingPathComponent("Sign in.command")
            let result = root.appendingPathComponent("result-\(exitCode)")
            try SignInFlow.command(executable: callback.path, attemptID: id, cli: cli.path)
                .write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", script.path]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "HEADROOM_TEST_EXIT": String(exitCode), "HEADROOM_TEST_RESULT": result.path
            ]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
            precondition(!FileManager.default.fileExists(atPath: directory.path), "finished attempts clean up their scripts")
            let arguments = try String(contentsOf: result, encoding: .utf8)
            let outcome = exitCode == 0 ? "--login-completed" : "--login-failed"
            precondition(arguments == "\(outcome)\n\(id)\n")
        }
        print("PASS sign-in outcomes distinguish success from cancellation/failure; quoted paths and cleanup work")

        var received: String?
        let observer = DistributedNotificationCenter.default().addObserver(forName: SignInFlow.notification,
            object: id, queue: .main) { received = $0.object as? String }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--login-completed", id]
        try child.run()
        let deadline = Date().addingTimeInterval(5)
        while received == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        child.waitUntilExit()
        precondition(received == id && child.terminationStatus == 0, "completion reaches the running app across processes")
        print("PASS login completion notification crosses processes")
    }
}
