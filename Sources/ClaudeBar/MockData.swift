import Foundation

/// Fabricated, clearly-fictional data used only to render screenshots for the
/// README. Never reflects the user's real `~/.claude` contents.
@MainActor
enum MockData {
    static func state() -> AppState {
        let s = AppState()
        s.sessions = sessions()
        s.usage = usage()
        s.rateLimit = rateLimit()
        s.globalMCP = globalMCP()
        s.projectMCP = projectMCP()
        s.account = account()
        s.lastRefresh = Date()
        AppSettings.shared.pinnedProjects = ["-Users-dev-work-mobile-app"]  // demo favorite
        return s
    }

    private static func liveProc(_ tty: String) -> LiveProcess {
        LiveProcess(id: 1000, tty: tty, cwd: nil,
                    termProgram: "Apple_Terminal", termSessionId: "MOCK")
    }

    private static func session(_ folder: String, branch: String?, model: String,
                                ctx: Int, limit: Int, status: SessionStatus,
                                live: Bool, agoSec: Double, activity: String? = nil) -> Session {
        let cwd = "/Users/dev/work/\(folder)"
        return Session(
            id: "mock-\(folder)",
            cwd: cwd,
            projectDirName: "-Users-dev-work-\(folder)",
            gitBranch: branch,
            model: model,
            lastActivity: Date().addingTimeInterval(-agoSec),
            status: status,
            live: live ? liveProc("ttys00\(abs(folder.hashValue) % 8)") : nil,
            activity: activity,
            contextTokens: ctx,
            contextLimit: limit
        )
    }

    private static func sessions() -> [Session] {
        [
            session("web-dashboard", branch: "feature/charts", model: "claude-opus-4-8",
                    ctx: 612_000, limit: 1_000_000, status: .busy, live: true, agoSec: 3,
                    activity: "Bash: npm test"),
            session("api-gateway", branch: "main", model: "claude-sonnet-4-6",
                    ctx: 88_000, limit: 200_000, status: .waiting, live: true, agoSec: 240,
                    activity: "리팩터링을 마쳤습니다. 다음 단계를 진행할까요?"),
            session("ml-pipeline", branch: "main", model: "claude-opus-4-8",
                    ctx: 145_000, limit: 1_000_000, status: .inactive, live: false, agoSec: 5400),
            session("mobile-app", branch: "release/2.0", model: "claude-opus-4-8",
                    ctx: 880_000, limit: 1_000_000, status: .inactive, live: false, agoSec: 9000),
            session("docs-site", branch: "main", model: "claude-haiku-4-5-20251001",
                    ctx: 32_000, limit: 200_000, status: .inactive, live: false, agoSec: 86_400),
            session("infra", branch: "main", model: "claude-sonnet-4-6",
                    ctx: 61_000, limit: 200_000, status: .inactive, live: false, agoSec: 172_800)
        ]
    }

    private static func rateLimit() -> RateLimitUsage {
        RateLimitUsage(windows: [
            RateWindow(id: "5h", title: "5시간 세션", utilization: 42,
                       resetsAt: Date().addingTimeInterval(2 * 3600 + 35 * 60)),
            RateWindow(id: "7d", title: "7일 (전체)", utilization: 18,
                       resetsAt: Date().addingTimeInterval(2 * 86_400 + 5 * 3600)),
            RateWindow(id: "7ds", title: "7일 (Sonnet)", utilization: 4,
                       resetsAt: Date().addingTimeInterval(2 * 86_400 + 5 * 3600))
        ], extraUsageEnabled: true)
    }

    private static func usage() -> UsageService.Snapshot {
        let daily: [DailyUsage] = (0..<30).reversed().map { offset in
            let day = Date().addingTimeInterval(-Double(offset) * 86_400)
            let pattern = [3, 8, 5, 2, 0, 0, 6, 12, 18, 9, 4, 1, 0, 7, 22, 30, 16, 11,
                           5, 2, 0, 9, 14, 19, 8, 3, 1, 6, 13, 20]
            let v = pattern[(29 - offset) % pattern.count]
            return DailyUsage(id: day, tokens: v * 1_000_000)
        }
        let windows = [
            UsageWindow(id: "5h", title: "최근 5시간", inputTokens: 248_000,
                        outputTokens: 812_000, cacheReadTokens: 64_300_000,
                        cacheCreationTokens: 1_900_000, costUSD: 4.20),
            UsageWindow(id: "7d", title: "최근 7일", inputTokens: 1_200_000,
                        outputTokens: 3_800_000, cacheReadTokens: 1_540_000_000,
                        cacheCreationTokens: 18_000_000, costUSD: 38.91)
        ]
        var models: [String: ModelTokenSum] = [:]
        models["claude-opus-4-8"] = ModelTokenSum(
            inputTokens: 900_000, outputTokens: 540_000,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 182.40)
        models["claude-sonnet-4-6"] = ModelTokenSum(
            inputTokens: 320_000, outputTokens: 210_000,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 24.10)
        models["claude-haiku-4-5-20251001"] = ModelTokenSum(
            inputTokens: 180_000, outputTokens: 96_000,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 2.80)

        return UsageService.Snapshot(
            windows: windows,
            daily: daily,
            lifetimeByModel: models,
            totalTokensHistory: daily.reduce(0) { $0 + $1.tokens },
            todayTokens: daily.last?.tokens ?? 0,
            todayCost: 4.20,
            historyCost: 247.63,
            topModel: "claude-opus-4-8",
            officialAvailable: false)
    }

    private static func globalMCP() -> [MCPServerInfo] {
        [
            MCPServerInfo(name: "playwright", scope: .global,
                          command: "npx @playwright/mcp@latest", transport: "stdio",
                          enabled: true, projectPath: nil),
            MCPServerInfo(name: "filesystem", scope: .global,
                          command: "npx @modelcontextprotocol/server-filesystem", transport: "stdio",
                          enabled: true, projectPath: nil)
        ]
    }

    private static func projectMCP() -> [MCPServerInfo] {
        [
            MCPServerInfo(name: "github", scope: .project, command: ".mcp.json",
                          transport: "stdio", enabled: true,
                          projectPath: "/Users/dev/work/web-dashboard"),
            MCPServerInfo(name: "postgres", scope: .project, command: ".mcp.json",
                          transport: "stdio", enabled: false,
                          projectPath: "/Users/dev/work/api-gateway")
        ]
    }

    private static func account() -> Account {
        Account(accountUuid: "00000000-0000-0000-0000-000000000000",
                email: "jane@example.com",
                displayName: "Jane Developer",
                organizationName: "Acme Inc.",
                organizationRole: "member",
                billingType: "stripe_subscription",
                isActive: true)
    }
}
