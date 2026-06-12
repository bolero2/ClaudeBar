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
    }

    private let d = UserDefaults.standard

    @Published var notifyWaiting: Bool { didSet { d.set(notifyWaiting, forKey: Key.notifyWaiting) } }
    @Published var notifyContext: Bool { didSet { d.set(notifyContext, forKey: Key.notifyContext) } }
    @Published var notifyRateLimit: Bool { didSet { d.set(notifyRateLimit, forKey: Key.notifyRateLimit) } }
    @Published var contextWarnPercent: Double { didSet { d.set(contextWarnPercent, forKey: Key.contextWarnPercent) } }
    @Published var rateWarnPercent: Double { didSet { d.set(rateWarnPercent, forKey: Key.rateWarnPercent) } }
    @Published var preferredTerminal: String { didSet { d.set(preferredTerminal, forKey: Key.preferredTerminal) } }

    private init() {
        notifyWaiting = (d.object(forKey: Key.notifyWaiting) as? Bool) ?? true
        notifyContext = (d.object(forKey: Key.notifyContext) as? Bool) ?? true
        notifyRateLimit = (d.object(forKey: Key.notifyRateLimit) as? Bool) ?? true
        contextWarnPercent = (d.object(forKey: Key.contextWarnPercent) as? Double) ?? 80
        rateWarnPercent = (d.object(forKey: Key.rateWarnPercent) as? Double) ?? 90
        preferredTerminal = (d.string(forKey: Key.preferredTerminal)) ?? "auto"
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
