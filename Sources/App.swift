import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private let client = UsageClient()
    private var timeline = RuntimeTimeline()
    private var refreshGate = RefreshGate()
    private var failures = 0
    private var problem: String?
    private var problemDetail: String?
    private let historyStore = HistoryStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Headroom/history.json"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let saved = historyStore.load() { timeline = RuntimeTimeline(restored: saved) }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Headroom"
        item.button?.alignment = .left
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
        for name in [NSLocale.currentLocaleDidChangeNotification, NSNotification.Name.NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(clockChanged), name: NSNotification.Name("AppleTimePreferencesChangedNotification"), object: nil)
        refresh()
    }

    @objc private func clockChanged() {
        Clock.invalidate()
        StatusStyle.invalidate()
        render()
    }

    @objc private func woke() { refresh() }

    @objc private func refresh() { fetch(manual: false) }

    private func fetch(manual: Bool) {
        render()
        guard refreshGate.begin(at: ContinuousClock.now, manual: manual) else { return }
        Task {
            var nextAttempt: ContinuousClock.Instant?
            var rateLimitUntil: ContinuousClock.Instant?
            do {
                let fetched = try await client.fetch()
                timeline.record(fetched)
                failures = 0
                nextAttempt = nil
                problem = nil
                problemDetail = nil
                saveHistory()
            } catch {
                failures += 1
                let backoff = Duration.seconds(min(900, 60 * pow(2, Double(min(failures - 1, 4)))))
                nextAttempt = ContinuousClock.now.advanced(by: backoff)
                switch error {
                case UsageError.signedOut:
                    problem = "Signed out"
                    problemDetail = "Sign into Claude Code, then refresh. Headroom does not launch Claude or change credentials."
                    nextAttempt = ContinuousClock.now.advanced(by: .seconds(300))
                case let UsageError.rateLimited(delay, receivedAt):
                    problem = "Usage rate limited"
                    problemDetail = "Claude asked Headroom to wait. Refresh now also respects this cooldown."
                    nextAttempt = receivedAt.advanced(by: max(backoff, delay))
                    rateLimitUntil = nextAttempt
                default:
                    problem = "Usage unavailable"
                    problemDetail = (error as? UsageError).flatMap {
                        if case let .message(message) = $0 { return message }
                        return nil
                    } ?? "Could not fetch Claude usage. Headroom will retry automatically."
                }
            }
            refreshGate.finish(nextAttempt: nextAttempt, rateLimitUntil: rateLimitUntil)
            render()
        }
    }

    private func render() {
        let instant = ContinuousClock.now
        let now = timeline.calendarNow(at: instant)
        let forecast = timeline.forecast(at: instant)
        let age = timeline.age(at: instant)
        let signedOut = problem == "Signed out"
        let title = signedOut ? "Signed out" : age > 600 && problem != nil ? "No data" : forecast.title(now: now)
        guard let button = item.button else { return }
        if button.title != title { button.title = title }
        let disabled = !signedOut && age > 180 && age <= 600
        if button.appearsDisabled != disabled { button.appearsDisabled = disabled }
        let image = claudeMenuBarImage(warning: !signedOut && forecast.isGap)
        if button.image !== image { button.image = image }
        let width = StatusStyle.width(forecast: signedOut ? .stale : forecast, title: title)
        if item.length != width { item.length = width }
        var detail = "Headroom · Claude quota\nInitial estimate uses average consumption since the quota window began. After a minute of live observations, uses the faster of the last 10 minutes and a 15–60 minute baseline, including idle time. Assumes this pace continues.\n"
        if let last = timeline.history.samples.last {
            detail += "Last updated: \(last.date.formatted(date: .omitted, time: .standard))\n"
            if let reset = last.reset { detail += "Reset: \(Clock.displayReset(reset).formatted(date: .abbreviated, time: .shortened))\n" }
        }
        if forecast == .estimating { detail += "Needs a usable window start or live observations at least one minute apart.\n" }
        if let problemDetail {
            detail += problemDetail + "\n"
            if let next = refreshGate.nextAttemptDate(at: instant, wallNow: Date()) {
                detail += "Next attempt: \(next.formatted(date: .omitted, time: .shortened))\n"
            }
        }
        detail += "Click for Refresh now, Launch at login, and Quit."
        if button.toolTip != detail { button.toolTip = detail }
        let label = signedOut ? "Claude is signed out. Sign into Claude Code." : title == "No data" ? "Claude usage data is unavailable." : forecast.accessibilityText
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        let value = age > 180 ? "Last successful update was more than three minutes ago." : ""
        if button.accessibilityValue() as? String != value { button.setAccessibilityValue(value) }
    }

    private func saveHistory() {
        try? historyStore.save(timeline.snapshot)
    }

    func menuWillOpen(_ menu: NSMenu) {
        render()
        menu.removeAllItems()
        let detail: String
        if let last = timeline.history.samples.last, let reset = last.reset {
            detail = "\(Int(last.used))% used · resets \(Clock.time(Clock.displayReset(reset)))"
        } else { detail = timeline.history.samples.isEmpty ? "Waiting for usage data" : "No active five-hour window" }
        menu.addItem(withTitle: detail, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let refreshItem = menu.addItem(withTitle: "Refresh now", action: #selector(manualRefresh), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = refreshGate.allowsManual(at: ContinuousClock.now)
        let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Headroom", action: #selector(quit), keyEquivalent: "")
        quit.target = self
    }

    @objc private func manualRefresh() {
        fetch(manual: true)
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
