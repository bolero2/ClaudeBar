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

    /// The cached entry for a session id, or nil if absent/unreadable.
    ///
    /// `maxAge` defaults to ~7 days, effectively unbounded: the statusLine stops
    /// re-rendering while a session sits idle, so the cache ts freezes even though
    /// the last context figure is still correct. The caller (`overlayLiveContext`)
    /// already gates on a live process, which is what makes the entry current —
    /// so we must NOT drop a frozen-but-valid cache for an idle live session.
    /// Session ids are UUIDs (never reused), so a long window can't mismatch.
    static func entry(for sessionId: String, maxAge: TimeInterval = 604_800) -> Entry? {
        let url = dir.appendingPathComponent(sessionId + ".json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.contextLimit > 0 else { return nil }
        let age = Date().timeIntervalSince1970 - entry.ts
        guard age <= maxAge else { return nil }
        return entry
    }
}
