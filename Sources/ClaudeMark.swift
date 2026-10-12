import AppKit

private enum ClaudeMark {
    static let plain = make(warning: false)
    static let warning = make(warning: true)

    private static func make(warning: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "Claude", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        let symbol = warning ? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) : nil
        let padded = NSImage(size: NSSize(width: warning ? 38 : 22, height: 18), flipped: false) { _ in
            image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            if warning { symbol?.draw(in: NSRect(x: 22, y: 3, width: 12, height: 12)) }
            return true
        }
        padded.isTemplate = true
        padded.accessibilityDescription = "Claude"
        return padded
    }
}

func claudeMenuBarImage(warning: Bool = false) -> NSImage? {
    warning ? ClaudeMark.warning : ClaudeMark.plain
}
