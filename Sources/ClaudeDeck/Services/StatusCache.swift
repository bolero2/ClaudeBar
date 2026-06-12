import Foundation

/// Reads the per-session context cache written by `claudedeck-statusline.sh`.
///
/// Claude Code 2.1.x no longer writes a live session's transcript (with `usage`
/// records) to `~/.claude/projects/<id>.jsonl` incrementally — it only flushes on
/// clean exit. So a *running* session's context/model can't be read from disk.
/// Claude Code does, however, hand that data to the configured statusLine command
/// on every render; our helper caches it here so ClaudeDeck can show live context
/// without parsing the terminal screen.
enum StatusCache {

    /// ~/.claude/claudedeck/status
    static var dir: URL {
        ClaudePaths.claudeDir
            .appendingPathComponent("claudedeck", isDirectory: true)
            .appendingPathComponent("status", isDirectory: true)
    }

    struct Entry: Decodable {
        let sessionId: String
        let cwd: String?
        let model: String?
        let contextTokens: Int
        let contextLimit: Int
        let usedPercentage: Double
        let ts: Double          // epoch seconds when the statusline last rendered

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cwd, model, ts
            case contextTokens = "context_tokens"
            case contextLimit = "context_limit"
            case usedPercentage = "used_percentage"
        }
    }

    /// The cached entry for a session id, or nil if absent/stale/unreadable.
    /// `maxAge` guards against using a frozen cache from a session that already
    /// ended (the helper stops updating it once the session exits).
    static func entry(for sessionId: String, maxAge: TimeInterval = 90) -> Entry? {
        let url = dir.appendingPathComponent(sessionId + ".json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.contextLimit > 0 else { return nil }
        let age = Date().timeIntervalSince1970 - entry.ts
        guard age <= maxAge else { return nil }
        return entry
    }
}
