import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var menuIsOpen = false
    private var displayTimer: Timer?
    private let engine = HeadroomEngine()
    private var server: HeadroomServer?
    private var signInAttempts = SignInAttempts()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onChange = { [weak self] in self?.render() }
        let server = HeadroomServer(engine: engine)
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("Headroom CLI unavailable: %@", (error as? HeadroomFailure)?.message ?? "Could not start local IPC.")
            if (error as? HeadroomFailure)?.code == "app_already_running" {
                NSApp.terminate(nil)
                return
            }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Headroom"
        item.button?.alignment = .left
        item.button?.font = StatusStyle.font
        item.button?.image = claudeMenuBarImage()
        item.button?.imagePosition = .imageLeading
        item.button?.imageHugsTitle = true
        menu.delegate = self
        menu.autoenablesItems = false
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(loginCompleted(_:)),
            name: SignInFlow.notification, object: nil)
        item.button?.target = self
        item.button?.action = #selector(showMenu)
        if let button = item.button {
            StatusMenu.installTrigger(on: button) { [weak self] in self?.showMenu() }
        }
        item.button?.setAccessibilityLabel("Claude usage forecast")
        render()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        for name in [NSLocale.currentLocaleDidChangeNotification, NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSSystemClockDidChange] {
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

    @objc private func refresh() { engine.refreshIfDue() }

    private func render() {
        guard !menuIsOpen else { return }
        let instant = ContinuousClock.now
        let now = Date()
        let snapshot = engine.status(at: instant, wallNow: now)
        displayTimer?.invalidate()
        displayTimer = nil
        if let deadline = snapshot.nextDisplayUpdate {
            displayTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, instant.duration(to: deadline).timeInterval), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.render() }
            }
            displayTimer?.tolerance = 2
        }
        let forecast = snapshot.forecast
        let age = snapshot.age
        let retryAt = snapshot.retryAt
        let presentation = snapshot.presentation
        let title = presentation.title
        guard let button = item.button else { return }
        if button.title != title { button.title = title }
        let disabled = presentation.appearsDisabled
        if button.appearsDisabled != disabled { button.appearsDisabled = disabled }
        let image = claudeMenuBarImage(warning: presentation.showsForecast && forecast.isGap)
        if button.image !== image { button.image = image }
        let width = StatusStyle.width(forecast: presentation.showsForecast ? forecast : .stale, title: title)
        if item.length != width { item.length = width }
        var detail = "Headroom · Claude quota\nUses the faster of the last 10 and 60 minutes of observed usage, including idle time and previous quota windows. Without a minute of observations, estimates pace from current-window consumption. Assumes this pace continues.\n"
        if let last = snapshot.sample {
            detail += "Last updated: \(last.date.formatted(date: .omitted, time: .standard))\n"
            detail += StatusPresentation.usageDetail(sample: last, now: snapshot.calendarNow) + "\n"
        }
        if forecast == .estimating { detail += "Needs a usable window start or live observations at least one minute apart.\n" }
        if let failure = snapshot.failure {
            detail += failure.message + "\n"
            if let retryAt {
                detail += "Next attempt: \(Clock.deadline(retryAt, relativeTo: now, seconds: true))\n"
            }
        }
        detail += "Click for Refresh now, Launch at login, and Quit."
        if button.toolTip != detail { button.toolTip = detail }
        let label = presentation.accessibilityText
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        let value = age > StatusPresentation.dimAfter ? "Last successful update was more than six minutes ago." : ""
        if button.accessibilityValue() as? String != value { button.setAccessibilityValue(value) }
    }

    @objc private func showMenu() {
        guard let button = item.button else { return }
        displayTimer?.invalidate()
        displayTimer = nil
        menuIsOpen = true
        defer {
            menuIsOpen = false
            render()
        }
        StatusMenu.present(menu, from: button)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let snapshot = engine.status()
        var detail = StatusPresentation.usageDetail(sample: snapshot.sample, now: snapshot.calendarNow)
        if snapshot.problem == .signedOut { detail = "Last update · " + detail }
        menu.addItem(withTitle: detail, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        if snapshot.problem == .signedOut {
            let signIn = menu.addItem(withTitle: "Sign in to Claude…", action: #selector(signIn), keyEquivalent: "")
            signIn.target = self
        }
        let refreshItem = menu.addItem(withTitle: "Refresh now", action: #selector(manualRefresh), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = snapshot.canRefresh
        let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Headroom", action: #selector(quit), keyEquivalent: "")
        quit.target = self
    }

    @objc private func manualRefresh() {
        Task { await engine.refresh() }
    }

    @objc private func signIn() {
        let attemptID = signInAttempts.begin()
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Headroom-login-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let script = directory.appendingPathComponent("Sign in to Claude.command")
            let command = SignInFlow.command(executable: Bundle.main.executableURL!.path, attemptID: attemptID)
            try command.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard NSWorkspace.shared.open(script) else { throw UsageError.message("Could not open Terminal.") }
        } catch {
            signInAttempts.finish(.init(attemptID: attemptID, succeeded: false))
            let alert = NSAlert()
            alert.messageText = "Open Terminal and run: claude auth login"
            alert.informativeText = "After signing in, choose Refresh now in Headroom."
            alert.runModal()
        }
    }

    @objc private func loginCompleted(_ notification: Notification) {
        guard let attemptID = notification.object as? String,
              let succeeded = notification.userInfo?["succeeded"] as? Bool,
              signInAttempts.finish(.init(attemptID: attemptID, succeeded: succeeded)) else { return }
        engine.loginCompleted()
    }

    func applicationWillTerminate(_ notification: Notification) { server?.stop() }

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
        let arguments = CommandLine.arguments
        if arguments.count > 1 && ["--login-completed", "--login-failed"].contains(arguments[1]) {
            guard let completion = SignInFlow.completion(arguments: arguments) else { exit(64) }
            SignInFlow.postCompletion(completion)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
