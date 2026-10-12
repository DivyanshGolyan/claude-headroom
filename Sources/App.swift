import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private let client = UsageClient()
    private var history = History()
    private var busy = false
    private var failures = 0
    private var nextAttempt = Date.distantPast
    private var rateLimitUntil = Date.distantPast
    private var problem: String?
    private var problemDetail: String?
    private let historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Headroom/history.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode(History.self, from: data) {
            history = saved
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Headroom"
        item.button?.font = StatusStyle.font
        item.button?.image = claudeMenuBarImage()
        item.button?.imagePosition = .imageLeading
        item.button?.imageHugsTitle = true
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.setAccessibilityLabel("Claude usage forecast")
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 2
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
    }

    @objc private func woke() { refresh() }

    @objc private func refresh() {
        render()
        guard !busy else { return }
        guard Date() >= nextAttempt else { return }
        busy = true
        Task {
            do {
                let sample = try await client.fetch()
                history.record(sample)
                failures = 0
                nextAttempt = .distantPast
                rateLimitUntil = .distantPast
                problem = nil
                problemDetail = nil
                saveHistory()
            } catch {
                failures += 1
                nextAttempt = Date().addingTimeInterval(min(900, 60 * pow(2, Double(min(failures - 1, 4)))))
                switch error {
                case UsageError.signedOut:
                    problem = "Signed out"
                    problemDetail = "Sign into Claude Code, then refresh. Headroom does not launch Claude or change credentials."
                    nextAttempt = Date().addingTimeInterval(5 * 60)
                case let UsageError.rateLimited(until):
                    problem = "Usage rate limited"
                    problemDetail = "Claude asked Headroom to wait. Refresh now also respects this cooldown."
                    nextAttempt = max(nextAttempt, until)
                    rateLimitUntil = nextAttempt
                default:
                    problem = "Usage unavailable"
                    problemDetail = (error as? UsageError).flatMap {
                        if case let .message(message) = $0 { return message }
                        return nil
                    } ?? "Could not fetch Claude usage. Headroom will retry automatically."
                }
            }
            busy = false
            render()
        }
    }

    private func render() {
        let forecast = Forecast.calculate(samples: history.samples, now: Date())
        let age = history.samples.last.map { Date().timeIntervalSince($0.date) } ?? .infinity
        let signedOut = problem == "Signed out"
        let title = signedOut ? "Signed out" : age > 600 && problem != nil ? "No data" : forecast.title()
        item.button?.title = title
        item.button?.alignment = .left
        item.button?.appearsDisabled = !signedOut && age > 180 && age <= 600
        item.button?.image = claudeMenuBarImage(warning: !signedOut && forecast.isGap)
        item.length = StatusStyle.width(forecast: signedOut ? .stale : forecast, title: title)
        var detail = "Headroom · Claude quota\nForecast uses the faster of the last 10 minutes and a 15–60 minute baseline, including idle time. Assumes this pace continues.\n"
        if let last = history.samples.last {
            detail += "Last updated: \(last.date.formatted(date: .omitted, time: .standard))\n"
            if let reset = last.reset { detail += "Reset: \(reset.formatted(date: .abbreviated, time: .shortened))\n" }
        }
        if forecast == .estimating { detail += "Needs five minutes of observations in this quota window.\n" }
        if let problemDetail { detail += problemDetail + "\nNext attempt: \(nextAttempt.formatted(date: .omitted, time: .shortened))\n" }
        detail += "Click for Refresh now, Launch at login, and Quit."
        item.button?.toolTip = detail
        item.button?.setAccessibilityLabel(signedOut ? "Claude is signed out. Sign into Claude Code." : title == "No data" ? "Claude usage data is unavailable." : forecast.accessibilityText)
        item.button?.setAccessibilityValue(age > 180 ? "Last successful update was more than three minutes ago." : "")
    }

    private func saveHistory() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(history)
            try data.write(to: historyURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch {
            // Forecasting continues in memory if the local cache cannot be written.
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        render()
        menu.removeAllItems()
        let detail: String
        if let last = history.samples.last, let reset = last.reset {
            detail = "\(Int(last.used))% used · resets \(Clock.time(reset))"
        } else { detail = history.samples.isEmpty ? "Waiting for usage data" : "No active five-hour window" }
        menu.addItem(withTitle: detail, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let refreshItem = menu.addItem(withTitle: "Refresh now", action: #selector(manualRefresh), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = !busy && Date() >= rateLimitUntil
        let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Headroom", action: #selector(quit), keyEquivalent: "")
        quit.target = self
    }

    @objc private func manualRefresh() {
        guard !busy, Date() >= rateLimitUntil else { return }
        nextAttempt = .distantPast
        refresh()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

@main
enum HeadroomApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
