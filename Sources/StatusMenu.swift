import AppKit

@MainActor
enum StatusMenu {
    static func present(_ menu: NSMenu, from button: NSStatusBarButton) {
        guard let window = button.window else { return }
        button.highlight(true)
        defer { button.highlight(false) }
        let frame = window.frame
        menu.minimumWidth = frame.width
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.minY - 8), in: nil)
    }
}
