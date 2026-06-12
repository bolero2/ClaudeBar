import Foundation
import SwiftUI
import Combine

/// Central observable store.
///
/// Two cadences: the cheap session/MCP/account probe runs frequently, while the
/// expensive usage aggregation (which reads up to 30 days of JSONL) runs on a
/// slower timer. The manual refresh button forces both.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var sessions: [Session] = []
    @Published var usage: UsageService.Snapshot?
    @Published var rateLimit: RateLimitUsage?
    @Published var globalMCP: [MCPServerInfo] = []
    @Published var projectMCP: [MCPServerInfo] = []
    @Published var account: Account?
    @Published var lastRefresh: Date?
    @Published var isRefreshing = false

    private var sessionTimer: AnyCancellable?
    private var usageTimer: AnyCancellable?
    private var usageRunning = false
    private var started = false

    var liveSessionCount: Int {
        sessions.filter { $0.live != nil }.count
    }

    /// Highest context fill among live sessions (0...1).
    var peakLiveContextFraction: Double {
        sessions.filter { $0.live != nil }
            .compactMap { $0.contextFraction }
            .max() ?? 0
    }

    /// True when a live session's context has crossed the warning threshold —
    /// drives the menu-bar alert icon.
    var contextWarning: Bool {
        peakLiveContextFraction >= SessionContext.warningFraction
    }

    /// Begins both refresh cadences. Called once at app launch (not on popover
    /// open) so data is ready before the user opens the menu.
    func start(sessionInterval: TimeInterval = 5, usageInterval: TimeInterval = 60) {
        guard !started else { return }
        started = true
        refreshSessions()
        refreshUsage()
        refreshRateLimit()
        sessionTimer = Timer.publish(every: sessionInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshSessions() }
        usageTimer = Timer.publish(every: usageInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshUsage()
                self?.refreshRateLimit()
            }
    }

    /// Manual refresh: both cadences at once.
    func refresh() {
        refreshRateLimit()
        refreshSessions()
        refreshUsage()
    }

    // MARK: - Cheap probe (sessions + config)

    func refreshSessions() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .utility) {
            let sessions = SessionScanner.scan()
            let config = ConfigStore()
            let globalMCP = config?.globalMCPServers() ?? []
            let projectMCP = config?.projectMCPServers() ?? []
            let account = config?.account()

            await MainActor.run {
                self.sessions = sessions
                self.globalMCP = globalMCP
                self.projectMCP = projectMCP
                self.account = account
                self.lastRefresh = Date()
                self.isRefreshing = false
            }
        }
    }

    // MARK: - Expensive probe (usage)

    func refreshUsage() {
        guard !usageRunning else { return }
        usageRunning = true
        // `.utility` (not `.background`): a menu-bar accessory app is rarely
        // focused, and `.background` QoS can be suspended for a long time,
        // leaving the Usage tab stuck on its loading state.
        Task.detached(priority: .utility) {
            let usage = UsageService.snapshot()
            await MainActor.run {
                self.usage = usage
                self.usageRunning = false
            }
        }
    }

    // MARK: - Official rate-limit usage

    private var rateLimitRunning = false

    func refreshRateLimit() {
        guard !rateLimitRunning else { return }
        rateLimitRunning = true
        Task.detached(priority: .utility) {
            let result = await OfficialUsageService.fetch()
            await MainActor.run {
                if let result { self.rateLimit = result }  // keep last good on failure
                self.rateLimitRunning = false
            }
        }
    }

    // MARK: - MCP toggle

    /// Enables/disables an MCP server, then reloads config to reflect the change.
    func toggleMCP(_ server: MCPServerInfo) {
        guard server.toggleable else { return }
        Task.detached(priority: .userInitiated) {
            _ = MCPService.toggle(server)
            await MainActor.run { self.reloadConfig() }
        }
    }

    /// Re-reads MCP + account from ~/.claude.json (cheap; no process scan).
    func reloadConfig() {
        let config = ConfigStore()
        globalMCP = config?.globalMCPServers() ?? []
        projectMCP = config?.projectMCPServers() ?? []
        account = config?.account()
    }

    // MARK: - Actions

    /// Live session → bring its terminal tab to the front.
    /// Ended session → open a new terminal window and `claude --resume` it.
    func activate(_ session: Session) {
        let cwd = session.cwd
        let id = session.id
        let live = session.live
        Task.detached(priority: .userInitiated) {
            if let live {
                _ = TerminalActivator.activate(live, cwd: cwd, sessionId: id)
            } else {
                _ = TerminalActivator.openResume(cwd: cwd, sessionId: id)
            }
        }
    }
}
