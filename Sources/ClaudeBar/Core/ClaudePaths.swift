import Foundation

/// Resolves well-known paths inside the user's ~/.claude directory.
enum ClaudePaths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/.claude
    static var claudeDir: URL {
        home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// ~/.claude.json  (global config: oauthAccount, mcpServers, projects[...])
    static var configFile: URL {
        home.appendingPathComponent(".claude.json", isDirectory: false)
    }

    /// ~/.claude/projects  (one sub-dir per cwd, each holding <sessionId>.jsonl files)
    static var projectsDir: URL {
        claudeDir.appendingPathComponent("projects", isDirectory: true)
    }

    /// ~/.claude/stats-cache.json
    static var statsCacheFile: URL {
        claudeDir.appendingPathComponent("stats-cache.json", isDirectory: false)
    }

    /// A project directory name like `-Users-alice-projects-my-app`
    /// maps back to the original cwd `/Users/alice/projects/my/app`.
    ///
    /// Claude encodes the cwd by replacing every `/` with `-`. The original
    /// path always starts at root, so the leading `-` becomes the leading `/`.
    /// Note: this is lossy for paths whose own segments contain `-`, which is
    /// why we still prefer the `cwd` recorded inside the JSONL when available.
    static func decodeProjectDirName(_ name: String) -> String {
        guard name.hasPrefix("-") else { return name }
        return "/" + name.dropFirst().replacingOccurrences(of: "-", with: "/")
    }

    /// Inverse of the encoding Claude uses for project dir names: every `/`
    /// becomes `-`. Unlike `decodeProjectDirName`, this direction is lossless,
    /// so it is the reliable way to match a real cwd to its project folder.
    static func encodeCwd(_ cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
    }
}
