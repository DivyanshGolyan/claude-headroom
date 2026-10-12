import AppKit

@MainActor
final class MenuProbe: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let widths: [CGFloat] = [180, 280, 100]
    private var index = 0
    private var failed = false
    private var openMenu: NSMenu?
    private var inspected = false
    private var rightClick = false
    private var pendingMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position HeadroomMenuTests": 0])
        item = NSStatusBar.system.statusItem(withLength: widths[0])
        item.autosaveName = "HeadroomMenuTests"
        item.button!.title = "Headroom test"
        StatusMenu.installTrigger(on: item.button!) { [unowned self] in
            if let menu = self.pendingMenu { StatusMenu.present(menu, from: self.item.button!) }
        }
        runNext()
    }

    private func runNext() {
        guard index < widths.count else {
            NSStatusBar.system.removeStatusItem(item)
            exit(failed ? 1 : 0)
        }
        item.length = widths[index]
        inspected = false
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Usage details", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Launch at login", action: nil, keyEquivalent: "").state = .on
        pendingMenu = menu
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if CommandLine.arguments.contains("--native") {
                self.item.menu = menu
                self.item.button!.performClick(nil)
                self.item.menu = nil
            } else {
                let button = self.item.button!
                let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                let event = NSEvent.mouseEvent(with: self.rightClick ? .rightMouseDown : .leftMouseDown,
                    location: location, modifierFlags: [], timestamp: 0, windowNumber: button.window!.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                button.window!.sendEvent(event)
            }
            self.check(self.inspected, "menu was presented and inspected")
            self.check(!self.item.button!.isHighlighted, "button highlight clears after dismissal")
            if self.rightClick { self.index += 1 }
            self.rightClick.toggle()
            self.runNext()
        }
    }

    private func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") width=\(widths[index]) \(rightClick ? "right" : "left") click: \(message)")
        if !condition { failed = true }
    }

    func menuWillOpen(_ menu: NSMenu) {
        openMenu = menu
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(inspectMenu), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func inspectMenu() {
        inspected = true
        let button = item.button!
        let frame = button.window!.frame
        let desktopTop = NSScreen.screens[0].frame.maxY
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let menuWindow = windows.first {
            $0[kCGWindowOwnerPID as String] as? Int == Int(getpid()) &&
            $0[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.popUpMenuWindow))
        }
        if let bounds = menuWindow?[kCGWindowBounds as String] as? [String: Any],
           let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
           let width = bounds["Width"] as? CGFloat, let screen {
            let expectedX = min(frame.minX, screen.frame.maxX - width)
            check(abs(x - expectedX) <= 2, "menu left edge follows highlighted cell, allowing screen-edge clamping")
            check(y >= desktopTop - frame.minY && y <= desktopTop - frame.minY + 12, "menu opens below button")
            check(width >= frame.width, "menu is at least as wide as highlighted cell")
            check(button.isHighlighted, "button stays highlighted while menu is open")
        } else {
            check(false, "visible button and menu window are measurable")
        }
        openMenu?.cancelTracking()
        openMenu = nil
    }
}

@main
enum StatusMenuTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = MenuProbe()
        app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}
