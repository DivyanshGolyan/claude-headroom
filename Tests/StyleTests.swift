import AppKit

@main enum StyleTests {
    static func main() {
        let plain = claudeMenuBarImage()!
        let warning = claudeMenuBarImage(warning: true)!
        precondition(plain === claudeMenuBarImage() && warning === claudeMenuBarImage(warning: true))
        precondition(plain !== warning && plain.isTemplate && warning.isTemplate)
        precondition(plain.size == NSSize(width: 22, height: 18) && warning.size == NSSize(width: 38, height: 18))
        func bitmap(_ image: NSImage) -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width), pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        for image in [plain, warning] {
            let pixels = bitmap(image)
            precondition((0..<18).contains { x in (0..<18).contains { y in pixels.colorAt(x: x, y: y)!.alphaComponent > 0 } }, "Claude logo must draw")
            precondition((18..<22).allSatisfy { x in (0..<18).allSatisfy { y in pixels.colorAt(x: x, y: y)!.alphaComponent == 0 } }, "Keep four transparent points after Claude logo")
        }
        let warningPixels = bitmap(warning)
        precondition((22..<34).contains { x in (0..<18).contains { y in warningPixels.colorAt(x: x, y: y)!.alphaComponent > 0 } }, "Warning symbol must draw")
        print("PASS cached template logos draw at original sizes with four-point spacing")
        let now = Date()
        var spareWidths = Set<Int>()
        var gapWidths = Set<Int>()
        var weeklyWidths = Set<Int>()
        for hour in 0..<24 {
            for minute in stride(from: 0, to: 60, by: 5) {
                let end = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
                let spare = Forecast.spare(95, end)
                let gap = Forecast.gap(end.addingTimeInterval(-3600), end)
                spareWidths.insert(Int(StatusStyle.width(forecast: spare, title: spare.title(now: now))))
                gapWidths.insert(Int(StatusStyle.width(forecast: gap, title: gap.title(now: now))))
                for offset in 0..<7 {
                    let reset = Calendar.current.date(byAdding: .day, value: offset, to: end)!
                    let weekly = Forecast.gap(reset.addingTimeInterval(-3600), reset, "Weekly")
                    weeklyWidths.insert(Int(StatusStyle.width(forecast: weekly, title: weekly.title(now: now))))
                }
            }
        }
        precondition(spareWidths.count == 1 && gapWidths.count == 1 && weeklyWidths.count == 1, "Widths changed: spare \(spareWidths), gap \(gapWidths), weekly \(weeklyWidths)")
        let one = ("11111" as NSString).size(withAttributes: [.font: StatusStyle.font]).width
        let eight = ("88888" as NSString).size(withAttributes: [.font: StatusStyle.font]).width
        precondition(abs(one - eight) < 0.01, "Digits are not tabular")
        print("PASS widths remain fixed across all clock times and weekly weekdays")
        print("PASS 1 and 8 have identical tabular widths")
    }
}
