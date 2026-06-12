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

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .short
        return f
    }()

    static func ago(_ date: Date) -> String {
        relative.localizedString(for: date, relativeTo: Date())
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
