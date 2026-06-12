import Foundation
import SwiftUI
import AppKit

/// Headless self-check: runs every data source once and prints a summary.
/// Invoked with `ClaudeBar --probe` so the services can be verified against
/// real ~/.claude data without launching the menu bar UI.
enum Diagnostics {
    static func run() {
        print("== Claude Bar 진단 ==\n")

        let live = ProcessProbe.liveProcesses()
        print("● 라이브 claude 프로세스: \(live.count)")
        for p in live {
            print("  pid=\(p.pid) tty=\(p.tty ?? "-") term=\(p.termProgram ?? "-") cwd=\(p.cwd ?? "-")")
        }

        let sessions = SessionScanner.scan()
        let liveSessions = sessions.filter { $0.live != nil }
        let peakLive = liveSessions.compactMap { $0.contextFraction }.max() ?? 0
        let warn = peakLive >= SessionContext.warningFraction
        print("\n● 세션: 총 \(sessions.count), 실행 중 \(liveSessions.count) | 라이브 최대 컨텍스트 \(Int(peakLive*100))% | 경고=\(warn)")
        let detailed = sessions.prefix(SessionScanner.detailLimit)
        let resumeOK = detailed.filter { ClaudePaths.encodeCwd($0.cwd) == $0.projectDirName }.count
        print("  resume cwd 정합성: \(resumeOK)/\(detailed.count) (encode(cwd)==projectDir)")
        for s in sessions.prefix(8) {
            let ctx: String
            if let t = s.contextTokens, let f = s.contextFraction {
                ctx = "ctx \(Format.tokens(t))/\(SessionContext.windowLabel(s.contextLimit)) \(Int(f*100))%"
            } else {
                ctx = "ctx -"
            }
            print("  [\(s.status.label)] \(s.folderName) | \(Format.model(s.model)) | \(ctx) | \(Format.ago(s.lastActivity))")
        }

        let t0 = ProcessInfo.processInfo.systemUptime
        let usage = UsageService.snapshot()
        let t1 = ProcessInfo.processInfo.systemUptime
        _ = UsageService.snapshot()   // second call should hit the per-file cache
        let t2 = ProcessInfo.processInfo.systemUptime
        print(String(format: "\n● 사용량 (공식연동=%@) [1회차 %.0fms, 캐시후 %.0fms]",
                     "\(usage.officialAvailable)", (t1 - t0) * 1000, (t2 - t1) * 1000))
        for w in usage.windows {
            print("  \(w.title): 합계 \(Format.tokens(w.totalTokens)) (입력 \(Format.tokens(w.inputTokens)), 출력 \(Format.tokens(w.outputTokens)), 캐시읽기 \(Format.tokens(w.cacheReadTokens)))")
        }
        print(String(format: "  비용 추정: 오늘 $%.2f, %d일 $%.2f, 5h $%.2f, 7d $%.2f",
                     usage.todayCost, UsageService.historyDays, usage.historyCost,
                     usage.windows.first?.costUSD ?? 0, usage.windows.last?.costUSD ?? 0))
        let nonZero = usage.daily.filter { $0.tokens > 0 }.count
        let peak = usage.daily.max { $0.tokens < $1.tokens }
        print("  일별 히스토그램: \(usage.daily.count)일 (활동 \(nonZero)일), 오늘 \(Format.tokens(usage.todayTokens)), \(UsageService.historyDays)일합계 \(Format.tokens(usage.totalTokensHistory))")
        if let peak { print("  최대일: \(Format.tokens(peak.tokens)) tokens, Top모델 \(Format.model(usage.topModel))") }

        let config = ConfigStore()
        let gmcp = config?.globalMCPServers() ?? []
        let pmcp = config?.projectMCPServers() ?? []
        print("\n● MCP: 전역 \(gmcp.count), 프로젝트 \(pmcp.count)")
        for m in gmcp { print("  [전역] \(m.name) (\(m.transport)) -> \(m.command)") }
        for m in pmcp.prefix(6) { print("  [\(m.enabled ? "on" : "off")] \(m.name) @ \((m.projectPath as NSString?)?.lastPathComponent ?? "-")") }

        if let acct = config?.account() {
            print("\n● 계정: \(acct.displayName ?? "-") <\(acct.email)> | org=\(acct.organizationName ?? "-") role=\(acct.organizationRole ?? "-")")
        }

        print("\n== 진단 완료 ==")
    }

    /// Renders the popover (at the given tab) to a PNG so the layout can be
    /// inspected headlessly. Usage: `ClaudeBar --render <tab> <path> [mock]`.
    /// With `mock`, fabricated data is used (for README screenshots) so no real
    /// session/account data is ever captured.
    @MainActor
    static func render(tab: Tab, to path: String, mock: Bool = false) {
        let state: AppState
        if mock {
            state = MockData.state()
        } else {
            state = AppState()
            state.sessions = SessionScanner.scan()
            let config = ConfigStore()
            state.globalMCP = config?.globalMCPServers() ?? []
            state.projectMCP = config?.projectMCPServers() ?? []
            state.account = config?.account()
            state.usage = UsageService.snapshot()
        }

        // ImageRenderer captures Text reliably but renders ScrollView content
        // blank, so render the scroll-less content variant in a fixed frame.
        let view = AnyView(
            VStack(spacing: 0) {
                switch tab {
                case .usage: UsageView(scroll: false)
                case .sessions: SessionListView(scroll: false)
                case .mcp: MCPView(scroll: false)
                case .account: AccountView(scroll: false)
                case .settings: SettingsView()
                }
            }
            .frame(width: 380)
            .background(Color(nsColor: .windowBackgroundColor))
            .environmentObject(state)
        )
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("렌더 실패"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("렌더 저장: \(path)")
    }

    /// Renders the full dashboard window to a PNG. Usage:
    /// `ClaudeBar --render dashboard <path> [mock]`.
    @MainActor
    static func renderDashboard(to path: String, mock: Bool = false) {
        let state: AppState
        if mock {
            state = MockData.state()
        } else {
            state = AppState()
            state.sessions = SessionScanner.scan()
            let config = ConfigStore()
            state.globalMCP = config?.globalMCPServers() ?? []
            state.projectMCP = config?.projectMCPServers() ?? []
            state.account = config?.account()
            state.usage = UsageService.snapshot()
        }
        let view = AnyView(
            DashboardView(screenshot: true)
                .frame(width: 880, height: 560)
                .background(Color(nsColor: .windowBackgroundColor))
                .environmentObject(state)
        )
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("대시보드 렌더 실패"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("대시보드 렌더 저장: \(path)")
    }

    /// Renders the app logo to a PNG (for README / branding).
    @MainActor
    static func renderLogo(to path: String) {
        let renderer = ImageRenderer(content: LogoView())
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("로고 렌더 실패"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("로고 저장: \(path)")
    }
}

/// App icon / logo: a coral rounded square with a sparkle over a mini bar chart.
private struct LogoView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 112, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.92, green: 0.56, blue: 0.43),
                             Color(red: 0.80, green: 0.38, blue: 0.28)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 26) {
                Image(systemName: "sparkle")
                    .font(.system(size: 150, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(alignment: .bottom, spacing: 16) {
                    bar(58); bar(96); bar(140); bar(82)
                }
            }
        }
        .frame(width: 512, height: 512)
    }

    private func bar(_ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.white.opacity(0.92))
            .frame(width: 28, height: h)
    }
}
