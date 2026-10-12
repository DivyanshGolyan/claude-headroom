import AppKit

final class EventApplication: NSApplication {
    var testEvent: NSEvent?
    override var currentEvent: NSEvent? { testEvent ?? super.currentEvent }
}

@main
enum MenuTriggerTests {
    static func main() {
        let application = EventApplication.shared as! EventApplication
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 24),
            styleMask: .borderless, backing: .buffered, defer: false)
        let trigger = StatusMenuTrigger(frame: window.contentView!.bounds)
        trigger.autoresizingMask = [.width, .height]
        var clicks = 0
        trigger.onClick = { clicks += 1 }
        window.contentView!.addSubview(trigger)
        window.orderFront(nil)
        for (index, type) in [NSEvent.EventType.leftMouseDown, .rightMouseDown].enumerated() {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 60, y: 12), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: index,
                clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            precondition(clicks == index + 1, "mouse event \(type) must reach the menu action; observed \(clicks) clicks")
        }
        window.setContentSize(NSSize(width: 240, height: 24))
        precondition(trigger.frame.width == 240, "the trigger follows status cell width changes")
        for modifiers: NSEvent.ModifierFlags in [[.command], [.command, .shift], [.command, .option]] {
            application.testEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 60, y: 12),
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 3, clickCount: 1, pressure: 1)!
            precondition(window.contentView!.hitTest(NSPoint(x: 60, y: 12)) === window.contentView,
                "Command-modified presses must hit the native parent, not the menu trigger")
        }
        application.testEvent = nil
        window.orderOut(nil)
        print("PASS native window dispatch sends left and right clicks to the same menu action")
    }
}
