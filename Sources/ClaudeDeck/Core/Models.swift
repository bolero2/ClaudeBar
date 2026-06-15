import Foundation

// MARK: - Session

/// Runtime status of a Claude Code session, derived heuristically from the
/// presence of a live `claude` process and how recently its JSONL was written.
enum SessionStatus: String {
    case busy        // live process + JSONL written within the last few seconds
    case waiting     // live process but idle (awaiting user input)
    case inactive    // no live process for this cwd

    var label: String {
        switch self {
        case .busy: return "진행 중"
        case .waiting: return "대기"
        case .inactive: return "종료됨"
        }
    }

    var symbol: String {
        switch self {
        case .busy: return "circle.fill"
        case .waiting: return "pause.circle.fill"
        case .inactive: return "moon.zzz"
        }
    }
}

/// A Claude Code session, reconstructed from `~/.claude/projects/<dir>/<id>.jsonl`.
struct Session: Identifiable {
    let id: String                 // session UUID (the JSONL filename)
    var cwd: String                // working directory (real path from JSONL when known)
    let projectDirName: String     // encoded folder name under projects/
    var gitBranch: String?
    var model: String?
    var lastActivity: Date
    var status: SessionStatus
    var live: LiveProcess?

    /// What the latest assistant turn is doing (running tool or last message),
    /// for live sessions. nil when unknown.
    var activity: String?

    /// Latest permission mode: "default" | "plan" | "acceptEdits" | "bypassPermissions".
    var permissionMode: String?

    /// Whether `claude --resume <id>` can actually restore this session — i.e. the
    /// transcript on disk holds at least one conversation message. Claude Code 2.x
    /// buffers the transcript in memory and only flushes it on a *clean* exit, so a
    /// session force-quit via Command+Q (which kills `claude` before the flush)
    /// leaves only an `ai-title` stub with no messages. Resuming such a session
    /// fails with "No conversation found"; we open a fresh session instead.
    var resumable: Bool = true

    /// Current context size = the latest assistant turn's prompt + output
    /// (input + cache_read + cache_creation + output). nil if unknown.
    var contextTokens: Int?
    /// Inferred context window for this session (200K standard, 1M extended).
    var contextLimit: Int = SessionContext.standardWindow

    var folderName: String {
        (cwd as NSString).lastPathComponent
    }

    /// 0...1 fraction of the context window in use.
    var contextFraction: Double? {
        guard let t = contextTokens, contextLimit > 0 else { return nil }
        return min(1, Double(t) / Double(contextLimit))
    }
}

enum SessionContext {
    static let standardWindow = 200_000
    static let extendedWindow = 1_000_000
    /// Fraction of the window at which a live session triggers the menu-bar alert.
    static let warningFraction = 0.80

    /// Infers the context window. A session is treated as 1M when either it has
    /// already exceeded 200K (a hard fact) or the project's recorded model usage
    /// includes the matching `[1m]` variant (reliable for active sessions that
    /// have not yet filled the standard window).
    static func inferWindow(maxObserved: Int, configExtended: Bool) -> Int {
        (maxObserved > standardWindow || configExtended) ? extendedWindow : standardWindow
    }

    static func windowLabel(_ limit: Int) -> String {
        limit >= extendedWindow ? "1M" : "200K"
    }
}

// MARK: - Scheduled prompts (input queue)

/// One queued prompt that is auto-typed into a session the next time it goes
/// idle. The app injects them one at a time: prompt → work → next prompt → …
struct ScheduledPrompt: Identifiable, Codable, Equatable {
    var id: String
    var text: String

    init(id: String = UUID().uuidString, text: String) {
        self.id = id
        self.text = text
    }
}

// MARK: - Compact templates

/// A saved `/compact` instruction the user can apply to a live session from the
/// session's right-click menu. An empty `prompt` means a plain `/compact`.
struct CompactTemplate: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var prompt: String

    init(id: String = UUID().uuidString, name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}

// MARK: - Live process

/// A running `claude` CLI process discovered via `ps`/`lsof`, used to mark
/// sessions live and to activate the owning terminal tab.
struct LiveProcess: Identifiable {
    let id: Int32          // pid
    var pid: Int32 { id }
    let tty: String?       // e.g. "ttys000"
    var cwd: String?
    var termProgram: String?   // "Apple_Terminal", "iTerm.app", ...
    var termSessionId: String?
}

// MARK: - Usage

/// One day's total token usage, for the daily histogram.
struct DailyUsage: Identifiable {
    let id: Date     // start of day (local)
    let tokens: Int
    var date: Date { id }
}

struct UsageWindow: Identifiable {
    let id: String          // label key
    let title: String       // "최근 5시간", "최근 7일"
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let costUSD: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }
}

// MARK: - Official rate-limit usage (/api/oauth/usage)

/// One rate-limit window from Claude's `/usage`: percent used + reset time.
struct RateWindow: Identifiable {
    let id: String
    let title: String
    let utilization: Double   // 0...100 percent used
    let resetsAt: Date?

    var remaining: Double { max(0, 100 - utilization) }
}

struct RateLimitUsage {
    var windows: [RateWindow]
    var extraUsageEnabled: Bool
}

// MARK: - MCP

enum MCPScope: String {
    case global = "전역"
    case project = "프로젝트"
}

struct MCPServerInfo: Identifiable {
    var id: String { scope.rawValue + "/" + name + "/" + (projectPath ?? "") }
    let name: String
    let scope: MCPScope
    let command: String        // human-readable invocation summary
    let transport: String      // "stdio", "sse", "http"
    var enabled: Bool
    var projectPath: String?   // for project-scoped servers
    var toggleable: Bool = true   // inline project servers can't be toggled
}

// MARK: - Account

struct Account: Identifiable {
    var id: String { accountUuid }
    let accountUuid: String
    let email: String
    let displayName: String?
    let organizationName: String?
    let organizationRole: String?
    let billingType: String?
    var isActive: Bool
}
