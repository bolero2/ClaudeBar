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
        if let i = args.firstIndex(of: "--render"), i + 2 < args.count {
            let what = args[i + 1]
            let path = args[i + 2]
            MainActor.assumeIsolated {
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

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(state)
                .onAppear { state.refresh() }   // freshen on each open
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
        // Start loading immediately so the popover has data on first open.
        AppState.shared.start()
    }
}
