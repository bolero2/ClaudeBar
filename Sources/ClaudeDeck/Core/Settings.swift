import Foundation
import ServiceManagement

/// User settings, persisted in UserDefaults. UI binds to the `@Published`
/// properties; non-main-actor code (e.g. TerminalActivator) reads the raw keys
/// directly via `UserDefaults` since that is thread-safe.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Key {
        static let notifyWaiting = "notifyWaiting"
        static let notifyContext = "notifyContext"
        static let notifyRateLimit = "notifyRateLimit"
        static let contextWarnPercent = "contextWarnPercent"
        static let rateWarnPercent = "rateWarnPercent"
        static let preferredTerminal = "preferredTerminal"   // "auto" | "Terminal" | "iTerm"
        static let pinnedProjects = "pinnedProjects"
        static let language = "language"                      // "en" | "ko"
        static let compactTemplates = "compactTemplates"      // JSON-encoded [CompactTemplate]
        static let autoCheckUpdates = "autoCheckUpdates"      // check GitHub releases on launch
        static let scheduledQueues = "scheduledQueues"        // JSON [sessionId: [ScheduledPrompt]]
    }

    /// Built-in `/compact` presets, used until the user edits the list. The first
    /// is the comprehensive continuation summary.
    static let defaultCompactTemplates: [CompactTemplate] = [
        CompactTemplate(
            id: "preset-comprehensive",
            name: "종합 요약",
            prompt: "Produce a comprehensive continuation-oriented summary of the entire session, preserving all goals, requirements, constraints, technical findings, exact identifiers and paths, decisions and rationale, code changes, errors, test results, unresolved issues, current status, and next steps. Preserve enough detail to resume the work accurately without the original conversation; remove only repetition, filler, and obsolete intermediate reasoning. Preserve important Korean requirements and terminology verbatim when paraphrasing could change their meaning."),
        CompactTemplate(
            id: "preset-decisions",
            name: "결정·미해결만",
            prompt: "Keep only the key decisions, their rationale, and the open/unresolved issues. Drop resolved intermediate steps."),
    ]

    private let d = UserDefaults.standard

    @Published var notifyWaiting: Bool { didSet { d.set(notifyWaiting, forKey: Key.notifyWaiting) } }
    @Published var notifyContext: Bool { didSet { d.set(notifyContext, forKey: Key.notifyContext) } }
    @Published var notifyRateLimit: Bool { didSet { d.set(notifyRateLimit, forKey: Key.notifyRateLimit) } }
    @Published var contextWarnPercent: Double { didSet { d.set(contextWarnPercent, forKey: Key.contextWarnPercent) } }
    @Published var rateWarnPercent: Double { didSet { d.set(rateWarnPercent, forKey: Key.rateWarnPercent) } }
    @Published var preferredTerminal: String { didSet { d.set(preferredTerminal, forKey: Key.preferredTerminal) } }
    @Published var pinnedProjects: [String] { didSet { d.set(pinnedProjects, forKey: Key.pinnedProjects) } }
    @Published var language: String { didSet { d.set(language, forKey: Key.language) } }
    @Published var autoCheckUpdates: Bool { didSet { d.set(autoCheckUpdates, forKey: Key.autoCheckUpdates) } }
    @Published var compactTemplates: [CompactTemplate] {
        didSet {
            if let data = try? JSONEncoder().encode(compactTemplates) {
                d.set(data, forKey: Key.compactTemplates)
            }
        }
    }
    /// Per-session queue of prompts to auto-inject, keyed by session id.
    @Published var scheduledQueues: [String: [ScheduledPrompt]] {
        didSet {
            if let data = try? JSONEncoder().encode(scheduledQueues) {
                d.set(data, forKey: Key.scheduledQueues)
            }
        }
    }

    func isPinned(_ projectDirName: String) -> Bool {
        pinnedProjects.contains(projectDirName)
    }

    func togglePin(_ projectDirName: String) {
        if let i = pinnedProjects.firstIndex(of: projectDirName) {
            pinnedProjects.remove(at: i)
        } else {
            pinnedProjects.append(projectDirName)
        }
    }

    // MARK: - Compact templates

    func addCompactTemplate(name: String, prompt: String) {
        compactTemplates.append(CompactTemplate(name: name, prompt: prompt))
    }

    func updateCompactTemplate(_ template: CompactTemplate) {
        if let i = compactTemplates.firstIndex(where: { $0.id == template.id }) {
            compactTemplates[i] = template
        }
    }

    func deleteCompactTemplate(_ id: String) {
        compactTemplates.removeAll { $0.id == id }
    }

    // MARK: - Scheduled prompt queues

    func queue(for sessionId: String) -> [ScheduledPrompt] {
        scheduledQueues[sessionId] ?? []
    }

    func addPrompt(_ text: String, to sessionId: String) {
        var q = scheduledQueues[sessionId] ?? []
        q.append(ScheduledPrompt(text: text))
        scheduledQueues[sessionId] = q
    }

    func updatePrompt(_ promptId: String, text: String, in sessionId: String) {
        guard var q = scheduledQueues[sessionId],
              let i = q.firstIndex(where: { $0.id == promptId }) else { return }
        q[i].text = text
        scheduledQueues[sessionId] = q
    }

    func removePrompt(_ promptId: String, from sessionId: String) {
        guard var q = scheduledQueues[sessionId] else { return }
        q.removeAll { $0.id == promptId }
        scheduledQueues[sessionId] = q.isEmpty ? nil : q
    }

    func movePrompt(in sessionId: String, from: Int, to: Int) {
        guard var q = scheduledQueues[sessionId],
              q.indices.contains(from), to >= 0, to < q.count else { return }
        q.insert(q.remove(at: from), at: to)
        scheduledQueues[sessionId] = q
    }

    func clearQueue(_ sessionId: String) {
        scheduledQueues[sessionId] = nil
    }

    /// Pops the first prompt (used by the auto-injector); clears the key if empty.
    func dequeueFirst(_ sessionId: String) -> ScheduledPrompt? {
        guard var q = scheduledQueues[sessionId], !q.isEmpty else { return nil }
        let first = q.removeFirst()
        scheduledQueues[sessionId] = q.isEmpty ? nil : q
        return first
    }

    private init() {
        notifyWaiting = (d.object(forKey: Key.notifyWaiting) as? Bool) ?? true
        notifyContext = (d.object(forKey: Key.notifyContext) as? Bool) ?? true
        notifyRateLimit = (d.object(forKey: Key.notifyRateLimit) as? Bool) ?? true
        contextWarnPercent = (d.object(forKey: Key.contextWarnPercent) as? Double) ?? 80
        rateWarnPercent = (d.object(forKey: Key.rateWarnPercent) as? Double) ?? 90
        preferredTerminal = (d.string(forKey: Key.preferredTerminal)) ?? "auto"
        pinnedProjects = (d.array(forKey: Key.pinnedProjects) as? [String]) ?? []
        language = (d.string(forKey: Key.language)) ?? Loc.systemDefault
        autoCheckUpdates = (d.object(forKey: Key.autoCheckUpdates) as? Bool) ?? true
        if let data = d.data(forKey: Key.scheduledQueues),
           let decoded = try? JSONDecoder().decode([String: [ScheduledPrompt]].self, from: data) {
            scheduledQueues = decoded
        } else {
            scheduledQueues = [:]
        }
        if let data = d.data(forKey: Key.compactTemplates),
           let decoded = try? JSONDecoder().decode([CompactTemplate].self, from: data) {
            compactTemplates = decoded
        } else {
            compactTemplates = AppSettings.defaultCompactTemplates
        }
    }

    // MARK: - Launch at login (SMAppService, computed — not stored here)

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Fails for the bare executable (no registered bundle); ignore.
        }
        objectWillChange.send()
    }
}
