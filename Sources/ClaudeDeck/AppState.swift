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
    @Published var isCheckingUpdate = false
    /// Session ids whose prompt queue is armed (auto-injecting). Persisted so a
    /// queue that was actively injecting when the app quit resumes after relaunch
    /// (see `resumeArmedQueues`). The set is cleared automatically when a queue
    /// drains, its session ends, or the user stops it — so only genuinely
    /// in-flight queues are ever resumed.
    @Published var runningQueues: Set<String> = [] {
        didSet { Self.persistArmedQueues(runningQueues) }
    }

    /// UserDefaults key holding the armed-queue session ids (`[String]`).
    private static let armedQueuesKey = "armedQueues"

    private static func persistArmedQueues(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: armedQueuesKey)
    }

    private static func loadArmedQueues() -> [String] {
        (UserDefaults.standard.array(forKey: armedQueuesKey) as? [String]) ?? []
    }

    private static func unpersistArmedQueue(_ sid: String) {
        var ids = loadArmedQueues()
        ids.removeAll { $0 == sid }
        UserDefaults.standard.set(ids, forKey: armedQueuesKey)
    }

    /// Wired up by `AppDelegate` to open the full dashboard window.
    var onOpenDashboard: (() -> Void)?
    /// Wired up by `AppDelegate` to close the menu-bar popover. Called before any
    /// modal (NSAlert / NSOpenPanel) so the dialog isn't hidden behind the
    /// popover, which floats at a high window level. See `prepareForModal`.
    var onClosePopover: (() -> Void)?

    /// Brings the app forward for a modal and dismisses the popover first so the
    /// dialog can't appear behind it. No-op for the dashboard (a regular window).
    private func prepareForModal() {
        onClosePopover?()
        NSApp.activate(ignoringOtherApps: true)
    }

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
        resumeArmedQueues()
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
                    // Don't nag about idle input when a queue is about to fill it.
                    let armedQueue = runningQueues.contains(id)
                        && !AppSettings.shared.queue(for: id).isEmpty
                    if settings.notifyWaiting && !armedQueue {
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
        prepareForModal()
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

    /// Permanently deletes ended sessions: their transcript JSONL, status-cache
    /// entry, and any scheduled-prompt queue. Live sessions are never deleted —
    /// the caller already filters them out, and this re-filters as a hard guard.
    /// Confirms once with a count before removing, then refreshes the list.
    func deleteSessions(_ sessions: [Session]) {
        let targets = sessions.filter { $0.live == nil }
        guard !targets.isEmpty else { return }

        let alert = NSAlert()
        if let icon = Self.appIcon { alert.icon = icon }
        alert.messageText = L("세션을 삭제할까요?")
        alert.informativeText = "\(targets.count)\(L("개 — 세션 기록이 영구 삭제되며 되돌릴 수 없습니다."))"
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("삭제"))
        alert.addButton(withTitle: L("취소"))
        prepareForModal()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let settings = AppSettings.shared
        let fm = FileManager.default
        for s in targets {
            let jsonl = ClaudePaths.projectsDir
                .appendingPathComponent(s.projectDirName, isDirectory: true)
                .appendingPathComponent(s.id + ".jsonl", isDirectory: false)
            try? fm.removeItem(at: jsonl)
            try? fm.removeItem(at: StatusCache.dir.appendingPathComponent(s.id + ".json", isDirectory: false))
            stopQueue(s.id)
            settings.clearQueue(s.id)
            settings.setRemoteControl(s.id, enabled: false)
        }
        refreshSessions()
    }

    /// The bundled app logo. NSAlert/Dialogs otherwise fall back to the
    /// Launch-Services-registered icon, which is stale/generic for an ad-hoc
    /// bundle run from an arbitrary path — so we set it explicitly.
    static let appIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }()

    // MARK: - Scheduled prompt queue (screen-driven auto-injector)

    func isQueueRunning(_ sessionId: String) -> Bool { runningQueues.contains(sessionId) }

    /// Arms a session's queue and spawns the injector loop. The loop watches the
    /// terminal's *visible contents* (not the JSONL mtime, which Claude Code
    /// buffers) to inject one prompt at a time, only while Claude is idle.
    func startQueue(_ sessionId: String) {
        guard !AppSettings.shared.queue(for: sessionId).isEmpty else { return }
        guard !runningQueues.contains(sessionId) else { return }
        runningQueues.insert(sessionId)
        Task { await self.runQueueLoop(sessionId) }
    }

    /// Disarms; the running loop observes `runningQueues` and exits on its own.
    func stopQueue(_ sessionId: String) {
        runningQueues.remove(sessionId)
    }

    /// On launch, re-arm queues that were actively injecting when the app last
    /// quit. Resumption is deliberately conservative: a queue is only re-armed if
    /// its session is still live and it still has prompts pending, so we never
    /// inject into a session the user didn't leave running.
    func resumeArmedQueues() {
        for sid in Self.loadArmedQueues() {
            Task { await self.resumeArmedQueue(sid) }
        }
    }

    /// Waits for one armed session's live process to be rediscovered after
    /// relaunch (the terminal may still be coming up, and the first session scan
    /// is async), then re-arms it. Drops the armed flag if the queue is already
    /// empty or the session never returns within the grace window.
    private func resumeArmedQueue(_ sid: String, graceSec: TimeInterval = 90) async {
        guard !AppSettings.shared.queue(for: sid).isEmpty else {
            Self.unpersistArmedQueue(sid); return
        }
        let deadline = Date().addingTimeInterval(graceSec)
        while Date() < deadline {
            if liveProcess(for: sid) != nil {
                startQueue(sid)   // re-arms, re-persists, and spawns the loop
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        Self.unpersistArmedQueue(sid)
    }

    /// The live process currently backing a queued session (nil once it ends).
    private func liveProcess(for sessionId: String) -> LiveProcess? {
        sessions.first(where: { $0.id == sessionId })?.live
    }

    /// Drives one armed session: wait-for-idle → inject next → let it start →
    /// (next iteration waits for idle again). Exits when the queue drains, the
    /// session ends, or the user stops it. `onStep` reports progress (used by the
    /// `--queue-run` diagnostic; nil in the app).
    func runQueueLoop(_ sid: String, onStep: (@Sendable (String) -> Void)? = nil) async {
        let settings = AppSettings.shared
        while runningQueues.contains(sid), !settings.queue(for: sid).isEmpty {
            guard let live = liveProcess(for: sid) else {
                onStep?("세션 종료 — 중단"); break
            }
            // 1. Wait until Claude shows the idle input prompt (stable).
            onStep?("유휴 대기…")
            guard await waitForState(.idle, live, sid: sid, stable: 2, pollSec: 2, timeoutSec: 600) else {
                if !runningQueues.contains(sid) { break }    // stopped
                onStep?("유휴 대기 타임아웃 — 재시도"); continue
            }
            guard runningQueues.contains(sid), let next = settings.dequeueFirst(sid) else { break }
            // 2. Inject the prompt (types + submits).
            let text = next.text
            let r = await Task.detached { TerminalActivator.injectText(live, text: text) }.value
            onStep?("주입(\(r)): \(text)")
            // 3. Give Claude a moment to accept & start, then confirm it went
            //    busy (best-effort: an instant reply may skip the busy window).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = await waitForState(.busy, live, sid: sid, stable: 1, pollSec: 1, timeoutSec: 8)
        }
        runningQueues.remove(sid)
        onStep?("완료 (남은 \(settings.queue(for: sid).count)개)")
    }

    /// Polls the terminal screen until it reaches `target` for `stable`
    /// consecutive reads, or the session is disarmed / times out.
    private func waitForState(_ target: TerminalActivator.ScreenState, _ live: LiveProcess,
                              sid: String, stable: Int, pollSec: UInt64, timeoutSec: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        var streak = 0
        while runningQueues.contains(sid), Date() < deadline {
            let state = await Task.detached { TerminalActivator.claudeScreenState(live) }.value
            if state == target {
                streak += 1
                if streak >= stable { return true }
            } else {
                streak = 0
            }
            try? await Task.sleep(nanoseconds: pollSec * 1_000_000_000)
        }
        return false
    }

    // MARK: - Slash commands (/compact, /clear)

    /// Types a slash command into a live session's terminal tab and submits it.
    func sendSlashCommand(_ session: Session, _ command: String) {
        guard let live = session.live else { return }
        Task.detached(priority: .userInitiated) {
            _ = TerminalActivator.sendText(live, text: command)
        }
    }

    // MARK: - Remote control (per session)

    /// Persists the per-session remote-control flag and, when the session is
    /// live, reflects it into the terminal by sending `/remote-control on|off`.
    /// The persisted flag survives relaunch (the slash command can only be sent
    /// to a live terminal, so an ended session just remembers its last state).
    func setRemoteControl(_ session: Session, enabled: Bool) {
        AppSettings.shared.setRemoteControl(session.id, enabled: enabled)
        guard session.live != nil else { return }
        sendSlashCommand(session, enabled ? "/remote-control on" : "/remote-control off")
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
        prepareForModal()
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
        prepareForModal()
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

    // MARK: - Self-update (GitHub Releases)

    /// Checks for a newer release. On launch (`userInitiated == false`) it stays
    /// silent unless an update exists; a manual check also reports up-to-date /
    /// errors. On confirmation it downloads, swaps the bundle, and relaunches.
    func checkForUpdates(userInitiated: Bool) {
        guard !isCheckingUpdate else { return }
        // On launch, only the installed .app can self-update; skip the dev binary.
        guard userInitiated || UpdateService.canSelfUpdate else { return }
        isCheckingUpdate = true
        Task {
            let release = await UpdateService.latestRelease()
            isCheckingUpdate = false
            guard let release else {
                if userInitiated {
                    showUpdateInfo(L("업데이트 확인 실패"),
                                   L("네트워크 또는 GitHub 응답을 확인하세요."))
                }
                return
            }
            guard UpdateService.isNewer(release.version, than: UpdateService.currentVersion) else {
                if userInitiated {
                    showUpdateInfo(L("최신 버전입니다"),
                                   "\(L("현재 버전")) \(UpdateService.currentVersion)")
                }
                return
            }
            promptAndInstall(release)
        }
    }

    /// Prompts the user; on confirmation downloads + installs + relaunches.
    private func promptAndInstall(_ release: UpdateService.Release) {
        let alert = NSAlert()
        if let icon = Self.appIcon { alert.icon = icon }
        alert.messageText = "\(L("새 버전이 있습니다")) — \(release.tag)"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var info = "\(L("현재 버전")) \(UpdateService.currentVersion) → \(release.version)"
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(500)) }
        if !UpdateService.canSelfUpdate {
            info += "\n\n" + L("개발 빌드에서는 릴리즈 페이지로 이동합니다.")
        }
        alert.informativeText = info
        alert.addButton(withTitle: L("업데이트하기"))
        alert.addButton(withTitle: L("나중에"))
        prepareForModal()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Dev binary: can't swap a bundle — open the releases page instead.
        guard UpdateService.canSelfUpdate else {
            if let url = URL(string: "https://github.com/\(UpdateService.repo)/releases/latest") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        isCheckingUpdate = true
        Task {
            let error = await UpdateService.downloadAndInstall(release)
            isCheckingUpdate = false
            if let error {
                showUpdateInfo(L("업데이트 실패"), error)
            } else {
                NSApp.terminate(nil)   // helper swaps the bundle and relaunches
            }
        }
    }

    private func showUpdateInfo(_ title: String, _ body: String) {
        let alert = NSAlert()
        if let icon = Self.appIcon { alert.icon = icon }
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: L("확인"))
        prepareForModal()
        _ = alert.runModal()
    }
}
