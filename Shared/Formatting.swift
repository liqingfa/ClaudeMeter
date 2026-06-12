import Foundation
import SwiftUI

enum Fmt {
    /// 1234 -> "1.2K", 1_200_000 -> "1.2M".
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(n) / 1_000)
        default:
            return "\(n)"
        }
    }

    /// Percentage with no decimals: 4.0 -> "4%".
    static func percent(_ util: Double) -> String {
        "\(Int(util.rounded()))%"
    }

    /// Compact countdown to a reset time, e.g. "1h23m" or "6d 4h".
    static func remaining(until date: Date, now: Date = Date()) -> String {
        let secs = max(0, Int(date.timeIntervalSince(now)))
        let d = secs / 86_400
        let h = (secs % 86_400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    /// Absolute reset time, localized and short: "今天 11:50" / "6/19 03:00".
    static func resetClock(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
            return "今天 " + f.string(from: date)
        }
        if cal.isDateInTomorrow(date) {
            f.dateFormat = "HH:mm"
            return "明天 " + f.string(from: date)
        }
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }

    /// Bar/accent color by utilization: green -> amber -> red.
    static func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }
}
