import AppKit

@MainActor
enum StatusMenu {
    static func installTrigger(on button: NSStatusBarButton, action: @escaping () -> Void) {
        let trigger = StatusMenuTrigger(frame: button.bounds)
        trigger.autoresizingMask = [.width, .height]
        trigger.onClick = action
        button.addSubview(trigger)
    }

    static func present(_ menu: NSMenu, from button: NSStatusBarButton) {
        guard let window = button.window else { return }
        button.highlight(true)
        defer { button.highlight(false) }
        let frame = window.frame
        menu.minimumWidth = frame.width
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.minY - 8), in: nil)
    }
}

@MainActor
final class StatusMenuTrigger: NSView {
    var onClick: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onClick() }
}
