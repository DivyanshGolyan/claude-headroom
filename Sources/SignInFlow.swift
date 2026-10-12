import Foundation

enum SignInFlow {
    static let notification = Notification.Name("com.divyanshgolyan.headroom.login-completed")

    struct Completion {
        let attemptID: String
        let succeeded: Bool
    }

    static func completion(arguments: [String]) -> Completion? {
        guard arguments.count == 3, ["--login-completed", "--login-failed"].contains(arguments[1]),
              UUID(uuidString: arguments[2]) != nil else { return nil }
        return Completion(attemptID: arguments[2], succeeded: arguments[1] == "--login-completed")
    }

    static func postCompletion(_ completion: Completion) {
        DistributedNotificationCenter.default().postNotificationName(notification,
            object: completion.attemptID, userInfo: ["succeeded": completion.succeeded], deliverImmediately: true)
    }

    static func command(executable: String, attemptID: String, cli: String = "claude") -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/zsh -l
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        if \(quote(cli)) auth login; then
            \(quote(executable)) --login-completed \(quote(attemptID))
            printf '\\nSigned in. Headroom is refreshing usage automatically.\\n'
        else
            \(quote(executable)) --login-failed \(quote(attemptID))
            printf '\\nSign-in did not complete. Try Sign in to Claude again from Headroom.\\n'
        fi
        rm -- "$0"
        rmdir -- "${0:h}"
        """
    }
}

struct SignInAttempts {
    private(set) var outstanding: Set<String> = []

    mutating func begin() -> String {
        let id = UUID().uuidString
        outstanding.insert(id)
        return id
    }

    @discardableResult
    mutating func finish(_ completion: SignInFlow.Completion) -> Bool {
        outstanding.remove(completion.attemptID) != nil && completion.succeeded
    }
}
