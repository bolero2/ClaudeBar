import SwiftUI
import AppKit

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
    @StateObject private var state = AppState.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(state)
                .onAppear { state.refresh() }   // freshen on each open
                .id(settings.language)          // rebuild on language change
        } label: {
            // Sparkle + live-session count. Switches to a warning triangle when
            // a live session's context crosses the threshold.
            Image(systemName: state.contextWarning ? "exclamationmark.triangle.fill" : "sparkle")
                .foregroundStyle(state.contextWarning ? Color.orange : Color.primary)
            if state.liveSessionCount > 0 {
                Text("\(state.liveSessionCount)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Hides the Dock icon so the app lives purely in the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationService.requestAuthorization()
        // Start loading immediately so the popover has data on first open.
        AppState.shared.start()
    }
}
