import Foundation
import SwiftUI

extension Color {
    /// Claude's signature coral/orange, used for the usage histogram.
    static let claudeCoral = Color(red: 0.847, green: 0.459, blue: 0.341)
}

enum Format {
    /// 12 345 -> "12.3K", 1 200 000 -> "1.2M"
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

    static func cost(_ usd: Double) -> String {
        usd <= 0 ? "—" : String(format: "$%.2f", usd)
    }

    private static let relative = RelativeDateTimeFormatter()

    static func ago(_ date: Date) -> String {
        relative.unitsStyle = .short
        relative.locale = Locale(identifier: isEnglish ? "en_US" : "ko_KR")
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// Compact "time until reset".
    static func resetIn(_ date: Date?) -> String {
        guard let date else { return "—" }
        let secs = Int(date.timeIntervalSinceNow)
        let days = secs / 86_400
        let hours = (secs % 86_400) / 3600
        let mins = (secs % 3600) / 60
        if isEnglish {
            if secs <= 0 { return "resetting" }
            if days >= 1 { return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d" }
            if hours >= 1 { return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h" }
            return "in \(mins)m"
        }
        if secs <= 0 { return "곧 리셋" }
        if days >= 1 { return hours > 0 ? "\(days)일 \(hours)시간 후" : "\(days)일 후" }
        if hours >= 1 { return mins > 0 ? "\(hours)시간 \(mins)분 후" : "\(hours)시간 후" }
        return "\(mins)분 후"
    }

    /// Strips the long date suffix from model ids: "claude-opus-4-8" stays,
    /// "claude-haiku-4-5-20251001" -> "claude-haiku-4-5".
    static func model(_ id: String?) -> String {
        guard let id else { return "—" }
        let parts = id.split(separator: "-")
        if let last = parts.last, last.count == 8, Int(last) != nil {
            return parts.dropLast().joined(separator: "-")
        }
        return id
    }
}
