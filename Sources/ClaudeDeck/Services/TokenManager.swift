import Foundation

/// Provides a valid Claude OAuth access token, refreshing it when expired.
///
/// The refresh token is **single-use (rotates)**: each refresh returns a new
/// refresh token that invalidates the old one. To avoid logging Claude Code out,
/// new tokens are written back to the same Keychain item. The `actor` serializes
/// refreshes so we never rotate concurrently.
///
/// Strategy (safest first):
///   1. If the stored token is still valid → use it.
///   2. If expired, re-read the Keychain — Claude Code refreshes proactively
///      during normal use, so the token is usually already fresh (no rotation
///      by us).
///   3. Only if still expired do we refresh ourselves and write the new tokens
///      back. On any failure we keep the existing token and change nothing.
actor TokenManager {
    static let shared = TokenManager()

    private let service = "Claude Code-credentials"
    private let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let marginMs: Double = 60_000   // refresh 60s before expiry

    func validAccessToken() async -> String? {
        guard var creds = readCredentials(),
              var oauth = creds["claudeAiOauth"] as? [String: Any] else { return nil }
        let nowMs = Date().timeIntervalSince1970 * 1000

        if let access = oauth["accessToken"] as? String,
           expiresAt(oauth) - nowMs > marginMs {
            return access
        }

        // Re-read: Claude Code may have already refreshed (no rotation by us).
        if let fresh = readCredentials(),
           let foauth = fresh["claudeAiOauth"] as? [String: Any],
           let faccess = foauth["accessToken"] as? String,
           expiresAt(foauth) - nowMs > marginMs {
            return faccess
        }

        // Refresh ourselves and persist the rotated tokens.
        guard let refreshToken = oauth["refreshToken"] as? String,
              let new = await refresh(refreshToken: refreshToken) else {
            return oauth["accessToken"] as? String
        }
        oauth["accessToken"] = new.access
        oauth["refreshToken"] = new.refresh
        oauth["expiresAt"] = nowMs + new.expiresInSec * 1000
        creds["claudeAiOauth"] = oauth
        if let data = try? JSONSerialization.data(withJSONObject: creds) {
            writeCredentials(data)
        }
        return new.access
    }

    private func expiresAt(_ oauth: [String: Any]) -> Double {
        (oauth["expiresAt"] as? Double)
            ?? (oauth["expiresAt"] as? Int).map(Double.init)
            ?? 0
    }

    private func refresh(refreshToken: String)
        async -> (access: String, refresh: String, expiresInSec: Double)? {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("anthropic", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else { return nil }
        let expiresIn = (obj["expires_in"] as? Double)
            ?? (obj["expires_in"] as? Int).map(Double.init) ?? 28_800
        return (access, refresh, expiresIn)
    }

    // MARK: - Keychain (via `security`, consistent with the read path)

    private func readCredentials() -> [String: Any]? {
        let out = Shell.run("/usr/bin/security",
                            ["find-generic-password", "-s", service, "-w"])
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private func writeCredentials(_ data: Data) {
        guard let json = String(data: data, encoding: .utf8) else { return }
        _ = Shell.run("/usr/bin/security",
                      ["add-generic-password", "-U", "-s", service,
                       "-a", NSUserName(), "-w", json])
    }
}
