import Foundation

enum SignInFlow {
    static let notification = Notification.Name("com.divyanshgolyan.headroom.login-completed")

    static func completionID(arguments: [String]) -> String? {
        guard arguments.count == 3, arguments[1] == "--login-completed",
              UUID(uuidString: arguments[2]) != nil else { return nil }
        return arguments[2]
    }

    static func postCompletion(_ attemptID: String) {
        DistributedNotificationCenter.default().postNotificationName(notification,
            object: attemptID, userInfo: nil, deliverImmediately: true)
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
            printf '\\nSign-in did not complete. Try Sign in to Claude again from Headroom.\\n'
        fi
        rm -- "$0"
        rmdir -- "${0:h}"
        """
    }
}
