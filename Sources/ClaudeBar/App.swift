import SwiftUI
import AppKit
import Combine
import UserNotifications

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--probe") {
            Diagnostics.run()
            return
        }
        if args.contains("--notify-test") {
            NotificationService.requestAuthorization()
            Thread.sleep(forTimeInterval: 2)
            NotificationService.post(title: "Claude Bar", body: "알림이 정상 동작합니다 ✅")
            Thread.sleep(forTimeInterval: 2)
            print("notify available=\(NotificationService.available)")
            return
        }
        if let i = args.firstIndex(of: "--raise"), i + 1 < args.count {
            let proc = LiveProcess(id: 0, tty: args[i + 1], cwd: nil,
                                   termProgram: "Apple_Terminal", termSessionId: nil)
            let r = TerminalActivator.activate(proc, cwd: "/tmp", sessionId: "noop")
            print("raise \(args[i + 1]): \(r)")
            return
        }
        if args.contains("--ratelimit") {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                if let r = await OfficialUsageService.fetch() {
                    print("extra_usage=\(r.extraUsageEnabled)")
                    for w in r.windows {
                        print("  \(w.title): \(Int(w.utilization))% 사용, 리셋 \(Format.resetIn(w.resetsAt))")
                    }
                } else {
                    print("rate-limit 가져오기 실패 (토큰/네트워크/엔드포인트)")
                }
                sem.signal()
            }
            sem.wait()
            return
        }
        // Debug: `--mcp global <name> <on|off>` or `--mcp project <name> <on|off> <path>`
        if let i = args.firstIndex(of: "--mcp"), i + 3 < args.count {
            let scope = args[i + 1], name = args[i + 2], enable = args[i + 3] == "on"
            let r: MCPService.Result
            if scope == "global" {
                r = MCPService.setGlobalEnabled(name, enabled: enable)
            } else if i + 4 < args.count {
                r = MCPService.setProjectEnabled(projectPath: args[i + 4], name: name, enabled: enable)
            } else {
                r = .failed("project 경로 필요")
            }
            print("mcp \(scope) \(name) -> \(enable ? "on" : "off"): \(r)")
            return
        }
        if let i = args.firstIndex(of: "--render"), i + 2 < args.count {
            let what = args[i + 1]
            let path = args[i + 2]
            MainActor.assumeIsolated {
                if args.contains("en") { AppSettings.shared.language = "en" }
                else if args.contains("ko") { AppSettings.shared.language = "ko" }
                if what == "logo" {
                    Diagnostics.renderLogo(to: path)
                } else {
                    let mock = args.contains("mock")
                    Diagnostics.render(tab: Tab(rawValue: what) ?? .sessions, to: path, mock: mock)
                }
            }
            return
        }
        ClaudeBarApp.main()
    }
}

struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        // The UI lives in a status-item popover managed by AppDelegate; this
        // empty Settings scene just satisfies the SwiftUI App lifecycle.
        Settings { EmptyView() }
    }
}

/// Owns the menu-bar status item + popover, the global hotkey, and notification
/// click handling. The app is a pure menu-bar agent (no Dock icon).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hotKey: HotKeyManager?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        NotificationService.requestAuthorization()
        AppState.shared.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateStatusButton()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 500)
        popover.contentViewController = NSHostingController(
            rootView: RootView().environmentObject(AppState.shared))

        // Keep the menu-bar button in sync with live count / warning state.
        AppState.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in Task { @MainActor in self?.updateStatusButton() } }
            .store(in: &cancellables)

        // ⌥⌘C toggles the panel from anywhere.
        hotKey = HotKeyManager { [weak self] in
            Task { @MainActor in self?.togglePopover() }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let s = AppState.shared
        let symbol = s.contextWarning ? "exclamationmark.triangle.fill" : "sparkle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude Bar")
        image?.isTemplate = !s.contextWarning
        button.image = image
        button.imagePosition = .imageLeading
        button.title = s.liveSessionCount > 0 ? " \(s.liveSessionCount)" : ""
        button.contentTintColor = s.contextWarning ? .systemOrange : nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            AppState.shared.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Notification clicks

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let sid = response.notification.request.content.userInfo["sessionId"] as? String
        Task { @MainActor [weak self] in
            if let sid { AppState.shared.activateById(sid) }
            else { self?.togglePopover() }
        }
        completionHandler()
    }

    /// Show notifications even when the app is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
