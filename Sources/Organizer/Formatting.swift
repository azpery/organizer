import Foundation
import SwiftUI
import AppKit

extension Calendar {
    static let app: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "fr_FR")
        c.firstWeekday = 2
        c.timeZone = .current
        return c
    }()
}

enum Fmt {
    static func hms(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "3 h 25" / "45 min"
    static func short(_ t: TimeInterval) -> String {
        let m = max(0, Int(t)) / 60
        if m < 60 { return "\(m) min" }
        return String(format: "%d h %02d", m / 60, m % 60)
    }

    static func hours(_ t: TimeInterval) -> String {
        String(format: "%.2f", t / 3600).replacingOccurrences(of: ".", with: ",")
    }

    private static let timeF: DateFormatter = make("HH:mm")
    private static let dayF: DateFormatter = make("EEE d MMM")
    private static let longDayF: DateFormatter = make("EEEE d MMMM yyyy")
    private static let dateF: DateFormatter = make("dd/MM/yyyy")

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = format
        return f
    }

    static func time(_ d: Date) -> String { timeF.string(from: d) }
    static func date(_ d: Date) -> String { dateF.string(from: d) }
    static func longDay(_ d: Date) -> String { longDayF.string(from: d).capitalizedFirst }

    static func dayHeader(_ d: Date) -> String {
        let cal = Calendar.app
        if cal.isDateInToday(d) { return "Aujourd'hui" }
        if cal.isDateInYesterday(d) { return "Hier" }
        return dayF.string(from: d).capitalizedFirst
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: d)
    }

    static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 6 {
            self.init(.sRGB,
                      red: Double((v >> 16) & 0xFF) / 255,
                      green: Double((v >> 8) & 0xFF) / 255,
                      blue: Double(v & 0xFF) / 255)
        } else {
            self = .gray
        }
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#7A8CA3" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
