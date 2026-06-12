import Foundation

/// Fetches Claude's authoritative rate-limit usage (the data behind `/usage`)
/// from the undocumented OAuth endpoint, using the access token stored in the
/// macOS Keychain by Claude Code.
///
/// Security: the access token is read from the Keychain and used only in the
/// Authorization header; it is never logged or persisted.
/// Caveat: the endpoint is unofficial and may change. On any failure (expired
/// token, network, schema change) this returns nil and the UI falls back to the
/// local token aggregation.
enum OfficialUsageService {

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let userAgent = "claude-code/2.1.175"
    private static let keychainService = "Claude Code-credentials"

    static func fetch() async -> RateLimitUsage? {
        guard let token = await TokenManager.shared.validAccessToken() else { return nil }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return parse(obj)
    }

    // MARK: - Parsing

    private static func parse(_ obj: [String: Any]) -> RateLimitUsage {
        var windows: [RateWindow] = []
        func add(_ key: String, _ title: String) {
            guard let w = obj[key] as? [String: Any],
                  let util = w["utilization"] as? Double else { return }
            let reset = (w["resets_at"] as? String).flatMap(parseDate)
            windows.append(RateWindow(id: key, title: title, utilization: util, resetsAt: reset))
        }
        add("five_hour", "5시간 세션")
        add("seven_day", "7일 (전체)")
        add("seven_day_opus", "7일 (Opus)")
        add("seven_day_sonnet", "7일 (Sonnet)")

        let extra = (obj["extra_usage"] as? [String: Any])?["is_enabled"] as? Bool ?? false
        return RateLimitUsage(windows: windows, extraUsageEnabled: extra)
    }

    /// Parses ISO-8601 like "2026-06-12T19:20:00.111161+00:00" (microsecond
    /// fractional seconds, which the standard formatter rejects).
    private static func parseDate(_ s: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: s) { return d }

        // Strip the fractional seconds, keep the timezone, retry.
        if let dot = s.firstIndex(of: "."),
           let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let stripped = String(s[..<dot]) + String(s[tz...])
            let base = ISO8601DateFormatter()
            base.formatOptions = [.withInternetDateTime]
            return base.date(from: stripped)
        }
        return nil
    }
}
