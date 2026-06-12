import SwiftUI
import AppKit
import Combine
import UserNotifications

@main
enum Main {
    static func main() {
        setbuf(stdout, nil)   // unbuffered stdout so --queue-run/--test-* logs stream live when redirected
        let args = CommandLine.arguments
        if args.contains("--probe") {
            Diagnostics.run()
            return
        }
        if args.contains("--notify-test") {
            NotificationService.requestAuthorization()
            Thread.sleep(forTimeInterval: 2)
            NotificationService.post(title: "ClaudeDeck", body: "알림이 정상 동작합니다 ✅")
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
        if args.contains("--check-update") {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let cur = UpdateService.currentVersion
                if let r = await UpdateService.latestRelease() {
                    let newer = UpdateService.isNewer(r.version, than: cur)
                    print("current=\(cur) latest=\(r.tag)(\(r.version)) newer=\(newer)")
                    print("  zip=\(r.zipURL.absoluteString)")
                    print("  notes=\(r.notes.prefix(60).replacingOccurrences(of: "\n", with: " "))…")
                } else {
                    print("최신 릴리즈 조회 실패 (네트워크/레이트리밋/에셋 누락)")
                }
                sem.signal()
            }
            sem.wait()
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
        if args.contains("--test-queue") {
            MainActor.assumeIsolated { Diagnostics.testQueue() }
            return
        }
        if args.contains("--test-inject") {
            Diagnostics.testInject()
            return
        }
        // `--inject <tty> <text>` — one-shot injectText on a tty (verify type+submit).
        if let i = args.firstIndex(of: "--inject"), i + 2 < args.count {
            let proc = LiveProcess(id: 0, tty: args[i + 1], cwd: nil,
                                   termProgram: "Apple_Terminal", termSessionId: nil)
            let r = TerminalActivator.injectText(proc, text: args[i + 2])
            print("inject \(args[i + 1]): \(r)")
            return
        }
        // `--screen <tty>` — print screen-derived idle/busy state for a session.
        if let i = args.firstIndex(of: "--screen"), i + 1 < args.count {
            Diagnostics.screenProbe(tty: args[i + 1])
            return
        }
        // `--queue-run <cwd> <count> <text>` — drive the real queue against a real session.
        if let i = args.firstIndex(of: "--queue-run"), i + 3 < args.count {
            let cwd = args[i + 1]
            let count = Int(args[i + 2]) ?? 1
            let text = args[i + 3]
            // queueRun is @MainActor + async, so we must NOT block the main thread
            // (a semaphore wait would deadlock the MainActor task). Spin the main
            // run loop instead and exit when the task finishes.
            Task { @MainActor in
                await Diagnostics.queueRun(cwd: cwd, count: count, text: text)
                exit(0)
            }
            RunLoop.main.run()
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
                } else if what == "dashboard" {
                    Diagnostics.renderDashboard(to: path, mock: args.contains("mock"))
                } else {
                    let mock = args.contains("mock")
                    Diagnostics.render(tab: Tab(rawValue: what) ?? .sessions, to: path, mock: mock)
                }
            }
            return
        }
        ClaudeDeckApp.main()
    }
}

struct ClaudeDeckApp: App {
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
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hotKey: HotKeyManager?
    private var cancellables = Set<AnyCancellable>()
    private var dashboard: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        NotificationService.requestAuthorization()
        AppState.shared.start()
        AppState.shared.onOpenDashboard = { [weak self] in self?.openDashboard() }

        // Dock icon (shown when the dashboard makes the app `.regular`).
        if let icon = AppState.appIcon {
            NSApp.applicationIconImage = icon
        }

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

        // Launch straight into the dashboard window (e.g. `open -a ClaudeDeck --args --dashboard`).
        if CommandLine.arguments.contains("--dashboard") {
            openDashboard()
        }

        // Check GitHub Releases for a newer version (prompts the user if found).
        // A short delay lets the menu bar settle before any update dialog.
        if AppSettings.shared.autoCheckUpdates {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                AppState.shared.checkForUpdates(userInitiated: false)
            }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let s = AppState.shared
        let symbol = s.contextWarning ? "exclamationmark.triangle.fill" : "sparkle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClaudeDeck")
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

    // MARK: - Dashboard window

    /// Opens (or re-focuses) the full dashboard window. While it's open the app
    /// becomes a regular app (Dock icon + menu bar) so the window can take focus;
    /// closing it returns to a pure menu-bar agent.
    @objc func openDashboard() {
        if popover.isShown { popover.performClose(nil) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let w = dashboard {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(
            rootView: DashboardView().environmentObject(AppState.shared))
        let w = NSWindow(contentViewController: host)
        w.title = "ClaudeDeck"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 880, height: 580))
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        dashboard = w
        w.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.dashboard = nil
            NSApp.setActivationPolicy(.accessory)   // back to menu-bar agent
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
