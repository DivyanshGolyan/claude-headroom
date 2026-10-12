import Foundation

@main
enum SignInFlowTests {
    static func main() throws {
        if let id = SignInFlow.completionID(arguments: CommandLine.arguments) {
            SignInFlow.postCompletion(id)
            return
        }
        let id = UUID().uuidString
        precondition(SignInFlow.completionID(arguments: ["Headroom", "--login-completed", id]) == id)
        for args in [["Headroom"], ["Headroom", "--login-completed"],
                     ["Headroom", "--login-completed", "invalid"],
                     ["Headroom", "--login-completed", id, "extra"]] {
            precondition(SignInFlow.completionID(arguments: args) == nil)
        }

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
            if exitCode == 0 {
                let arguments = try String(contentsOf: result, encoding: .utf8)
                precondition(arguments == "--login-completed\n\(id)\n")
            } else {
                precondition(!FileManager.default.fileExists(atPath: result.path), "failed/cancelled login must not refresh")
            }
        }
        print("PASS sign-in success alone triggers completion; cancellation, failure, quoted paths and cleanup work")

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
