import AppKit
import CoreText

enum StatusStyle {
    static let font: NSFont = {
        let base = NSFont.menuBarFont(ofSize: 0)
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
        ]]])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }()

    private static var environment: (Locale, TimeZone, String)?
    private static var cachedDayTime: String?
    private static var measurements: [(String, CGFloat)] = []

    static func invalidate() {
        cachedDayTime = nil
        measurements.removeAll()
        environment = nil
    }

    private static var dayTime: String {
        if let cachedDayTime { return cachedDayTime }
        let value = (0..<7).flatMap { offset in
            let day = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
            return [11, 23].map { hour in
                let time = Calendar.current.date(bySettingHour: hour, minute: 55, second: 0, of: day)!
                return Clock.time(time, day: true, period: true)
                    .replacingOccurrences(of: "[0-9]", with: "0", options: .regularExpression)
            }
        }.max(by: { measure($0) < measure($1) }) ?? "Wed 00:00"
        cachedDayTime = value
        return value
    }

    private static func measure(_ text: String) -> CGFloat {
        if let cached = measurements.first(where: { $0.0 == text }) { return cached.1 }
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        if measurements.count == 16 { measurements.removeFirst() }
        measurements.append((text, width))
        return width
    }

    static func width(forecast: Forecast, title: String) -> CGFloat {
        let locale = Locale.current
        let zone = NSTimeZone.default
        let format = Clock.resolvedFormat(day: true, locale: locale)
        if environment?.0 != locale || environment?.1 != zone || environment?.2 != format {
            invalidate()
            environment = (locale, zone, format)
        }
        let widest: String
        switch forecast {
        case let .gap(_, _, name):
            widest = name.map { "\($0) out \(dayTime)–\(dayTime)" } ?? "Out 00:00–00:00"
        case let .out(_, name): widest = name.map { "\($0) out till \(dayTime)" } ?? "Out till 00:00"
        case .spare: widest = "100% spare till 00:00"
        default: widest = title
        }
        return max(measure(widest), measure(title)) + (forecast.isGap ? 38 : 22) + 14
    }
}
