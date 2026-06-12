import Foundation
import SwiftUI
import Combine
import AppKit

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

    /// Wired up by `AppDelegate` to open the full dashboard window.
    var onOpenDashboard: (() -> Void)?

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
        peakLiveContextFraction >= AppSettings.shared.contextWarnPercent / 100
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
                self.evaluateSessionNotifications(sessions)
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
                if let result {
                    self.rateLimit = result   // keep last good on failure
                    self.evaluateRateLimitNotifications(result)
                }
                self.rateLimitRunning = false
            }
        }
    }

    // MARK: - Notifications

    private var sessionsPrimed = false
    private var rateLimitPrimed = false
    private var waitingSince: [String: Date] = [:]   // session id -> first seen waiting
    private var waitNotified: [String: Bool] = [:]
    private var contextNotified: [String: Bool] = [:]
    private var rateNotified: [String: Bool] = [:]    // window id -> notified

    private static let waitDebounce: TimeInterval = 10

    /// Notifies when a live session goes idle (awaiting input) or its context
    /// crosses the warning threshold. The first pass only primes baseline state
    /// so pre-existing conditions at launch don't fire.
    private func evaluateSessionNotifications(_ sessions: [Session]) {
        let live = sessions.filter { $0.live != nil }
        let priming = !sessionsPrimed
        sessionsPrimed = true
        let settings = AppSettings.shared
        let contextThreshold = settings.contextWarnPercent / 100

        var liveIDs = Set<String>()
        for s in live {
            let id = s.id
            liveIDs.insert(id)

            // Awaiting input (live but idle, stable for a few seconds).
            if s.status == .waiting {
                let since = waitingSince[id] ?? Date()
                waitingSince[id] = since
                if priming {
                    waitNotified[id] = true
                } else if Date().timeIntervalSince(since) >= Self.waitDebounce,
                          waitNotified[id] != true {
                    if settings.notifyWaiting {
                        NotificationService.post(
                            title: L("입력 대기 중"),
                            body: "\(s.folderName) \(L("세션이 입력을 기다립니다."))",
                            sessionId: s.id)
                    }
                    waitNotified[id] = true
                }
            } else {
                waitingSince[id] = nil
                waitNotified[id] = false
            }

            // Context window threshold (crossing upward).
            let frac = s.contextFraction ?? 0
            if frac >= contextThreshold {
                if priming {
                    contextNotified[id] = true
                } else if contextNotified[id] != true {
                    if settings.notifyContext {
                        NotificationService.post(
                            title: L("컨텍스트 한도 임박"),
                            body: "\(s.folderName) \(L("컨텍스트")) \(Int(frac * 100))% · \(SessionContext.windowLabel(s.contextLimit))",
                            sessionId: s.id)
                    }
                    contextNotified[id] = true
                }
            } else {
                contextNotified[id] = false
            }
        }

        // Drop state for sessions no longer live.
        waitingSince = waitingSince.filter { liveIDs.contains($0.key) }
        waitNotified = waitNotified.filter { liveIDs.contains($0.key) }
        contextNotified = contextNotified.filter { liveIDs.contains($0.key) }
    }

    private func evaluateRateLimitNotifications(_ rate: RateLimitUsage) {
        let priming = !rateLimitPrimed
        rateLimitPrimed = true
        let settings = AppSettings.shared
        for w in rate.windows {
            if w.utilization >= settings.rateWarnPercent {
                if priming {
                    rateNotified[w.id] = true
                } else if rateNotified[w.id] != true {
                    if settings.notifyRateLimit {
                        NotificationService.post(
                            title: L("사용 한도 임박"),
                            body: "\(L(w.title)) \(Int(w.utilization))% \(L("사용")) · \(L("리셋")) \(Format.resetIn(w.resetsAt))")
                    }
                    rateNotified[w.id] = true
                }
            } else {
                rateNotified[w.id] = false
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
        // Reconstruct the original session's 1M window + permission mode on resume.
        let model = session.model
        let mode = session.permissionMode
        let extended = session.contextLimit >= SessionContext.extendedWindow
        Task.detached(priority: .userInitiated) {
            if let live {
                _ = TerminalActivator.activate(live, cwd: cwd, sessionId: id,
                                               resumeModel: model, permissionMode: mode,
                                               extendedContext: extended)
            } else {
                _ = TerminalActivator.openResume(cwd: cwd, sessionId: id,
                                                 resumeModel: model, permissionMode: mode,
                                                 extendedContext: extended)
            }
        }
    }

    /// Activates the session with the given id (jump to terminal / resume).
    func activateById(_ id: String) {
        if let s = sessions.first(where: { $0.id == id }) { activate(s) }
    }

    /// Opens a new terminal window and starts `claude` in the given directory.
    func newSession(cwd: String, skipPermissions: Bool = false) {
        Task.detached(priority: .userInitiated) {
            _ = TerminalActivator.openNew(cwd: cwd, skipPermissions: skipPermissions)
        }
    }

    /// Prompts for a directory, then starts a new session there.
    func newSessionInteractive(skipPermissions: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("새 세션 시작")
        panel.message = L("Claude Code를 시작할 디렉토리를 선택하세요")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            newSession(cwd: url.path, skipPermissions: skipPermissions)
        }
    }

    /// Sends SIGTERM to a live session's process.
    func killSession(_ session: Session) {
        guard let pid = session.live?.pid else { return }
        Task.detached(priority: .userInitiated) {
            kill(pid, SIGTERM)
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run { self.refreshSessions() }
        }
    }

    /// The bundled app logo. NSAlert/Dialogs otherwise fall back to the
    /// Launch-Services-registered icon, which is stale/generic for an ad-hoc
    /// bundle run from an arbitrary path — so we set it explicitly.
    static let appIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }()

    // MARK: - Slash commands (/compact, /clear)

    /// Types a slash command into a live session's terminal tab and submits it.
    func sendSlashCommand(_ session: Session, _ command: String) {
        guard let live = session.live else { return }
        Task.detached(priority: .userInitiated) {
            _ = TerminalActivator.sendText(live, text: command)
        }
    }

    /// `/compact`, optionally with a continuation instruction.
    func compact(_ session: Session, prompt: String = "") {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        sendSlashCommand(session, trimmed.isEmpty ? "/compact" : "/compact \(trimmed)")
    }

    /// Prompts for a one-off `/compact` instruction, then sends it.
    func compactWithCustomPrompt(_ session: Session) {
        let alert = NSAlert()
        if let icon = Self.appIcon { alert.icon = icon }
        alert.messageText = L("압축 문구 입력")
        alert.informativeText = "\(session.folderName) · /compact"
        alert.addButton(withTitle: L("압축"))
        alert.addButton(withTitle: L("취소"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.placeholderString = L("예: 핵심 결정과 미해결 이슈만 남겨줘")
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            compact(session, prompt: field.stringValue)
        }
    }

    /// `/clear` wipes the conversation, so confirm before sending.
    func clearSession(_ session: Session) {
        let alert = NSAlert()
        if let icon = Self.appIcon { alert.icon = icon }
        alert.messageText = L("이 세션의 대화를 비울까요?")
        alert.informativeText = "\(session.folderName) · /clear"
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("비우기"))
        alert.addButton(withTitle: L("취소"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            sendSlashCommand(session, "/clear")
        }
    }

    func revealInFinder(_ cwd: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }

    func copyPath(_ cwd: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cwd, forType: .string)
    }
}
