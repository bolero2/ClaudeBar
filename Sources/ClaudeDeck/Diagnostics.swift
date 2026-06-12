import Foundation
import SwiftUI
import AppKit

/// Headless self-check: runs every data source once and prints a summary.
/// Invoked with `ClaudeDeck --probe` so the services can be verified against
/// real ~/.claude data without launching the menu bar UI.
enum Diagnostics {
    static func run() {
        print("== ClaudeDeck 진단 ==\n")

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

    // MARK: - Prompt-queue self-tests

    /// Verifies the scheduled-prompt queue data layer (add/move/dequeue/clear)
    /// against `AppSettings`. Uses a throwaway session id and clears it after so
    /// the user's real queues are untouched. Usage: `ClaudeDeck --test-queue`.
    @MainActor
    static func testQueue() {
        print("== 예약 입력 큐 — 데이터 로직 테스트 ==\n")
        let s = AppSettings.shared
        let sid = "__diag_queue_\(Int(Date().timeIntervalSince1970))"
        var pass = 0, fail = 0
        func check(_ label: String, _ cond: Bool) {
            print("  [\(cond ? "PASS" : "FAIL")] \(label)")
            cond ? (pass += 1) : (fail += 1)
        }

        s.clearQueue(sid)
        check("초기 큐 비어있음", s.queue(for: sid).isEmpty)

        s.addPrompt("first", to: sid)
        s.addPrompt("second", to: sid)
        s.addPrompt("third", to: sid)
        check("3개 추가됨", s.queue(for: sid).map(\.text) == ["first", "second", "third"])

        s.movePrompt(in: sid, from: 2, to: 0)   // third → 맨 앞
        check("순서 이동(2→0)", s.queue(for: sid).map(\.text) == ["third", "first", "second"])

        let mid = s.queue(for: sid)[1].id
        s.removePrompt(mid, from: sid)
        check("중간 항목 삭제", s.queue(for: sid).map(\.text) == ["third", "second"])

        let popped = s.dequeueFirst(sid)
        check("dequeueFirst가 맨 앞 반환", popped?.text == "third")
        check("dequeue 후 1개 남음", s.queue(for: sid).map(\.text) == ["second"])

        s.movePrompt(in: sid, from: 0, to: 5)   // 범위 밖 — 무시되어야
        check("범위 밖 이동 무시", s.queue(for: sid).map(\.text) == ["second"])

        _ = s.dequeueFirst(sid)
        check("마지막 dequeue 후 키 정리됨(nil)", s.scheduledQueues[sid] == nil)
        check("빈 큐 dequeue는 nil", s.dequeueFirst(sid) == nil)

        s.clearQueue(sid)   // 정리
        print("\n결과: \(pass) PASS / \(fail) FAIL")
    }

    /// End-to-end test of the focus-stealing-free injector: spawns a throwaway
    /// Terminal window, injects a command into its tty via the real
    /// `TerminalActivator.injectText`, and confirms the command actually executed
    /// (it writes a sentinel file). No real Claude session is touched.
    /// Usage: `ClaudeDeck --test-inject`.
    static func testInject() {
        print("== 예약 입력 큐 — 실제 터미널 주입 테스트 ==\n")
        let sentinel = "CLAUDEDECK_INJECT_\(Int(Date().timeIntervalSince1970))"
        let outFile = "/tmp/claudedeck-inject-test.txt"
        try? FileManager.default.removeItem(atPath: outFile)

        // 1) 일회용 Terminal 창을 띄우고 그 tty를 받아온다.
        let openScript = """
        tell application "Terminal"
          set t to do script "echo DIAG_READY"
          delay 0.4
          return tty of t
        end tell
        """
        let tty = Shell.osascript(openScript).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tty.hasPrefix("/dev/tty") else {
            print("  [FAIL] 일회용 Terminal tty 확보 실패: '\(tty)'")
            return
        }
        let ttyName = String(tty.dropFirst("/dev/".count))  // "ttys00x"
        print("  일회용 창 tty=\(tty)")

        // 2) 포커스를 일부러 Finder로 옮겨, 주입이 포커스를 뺏는지 관찰할 기준을 만든다.
        func frontmostApp() -> String {
            Shell.osascript(
                "tell application \"System Events\" to return name of first process whose frontmost is true"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = Shell.osascript("tell application \"Finder\" to activate")
        Thread.sleep(forTimeInterval: 0.6)
        let frontBefore = frontmostApp()
        print("  주입 전 최전면 앱: \(frontBefore)")

        // 3) 그 세션을 가리키는 가짜 LiveProcess로 실제 주입 경로를 호출.
        let proc = LiveProcess(id: 0, tty: ttyName, cwd: nil,
                               termProgram: "Apple_Terminal", termSessionId: nil)
        let cmd = "echo \(sentinel) > \(outFile)"
        let result = TerminalActivator.injectText(proc, text: cmd)
        print("  injectText 결과: \(result)")

        // 4) 주입 직후 최전면 앱이 그대로인지(=Terminal로 안 바뀜) 확인.
        Thread.sleep(forTimeInterval: 0.4)
        let frontAfter = frontmostApp()
        let focusKept = frontAfter == frontBefore && frontAfter != "Terminal"
        print("  주입 후 최전면 앱: \(frontAfter)")

        // 5) 셸이 명령을 실행할 시간을 준 뒤 결과 파일을 확인.
        Thread.sleep(forTimeInterval: 1.2)
        let got = (try? String(contentsOfFile: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let executed = got == sentinel

        // 6) 일회용 창 정리.
        let closeScript = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                close w
                return "closed"
              end if
            end repeat
          end repeat
        end tell
        """
        _ = Shell.osascript(closeScript)
        try? FileManager.default.removeItem(atPath: outFile)

        print("\n  주입된 명령: \(cmd)")
        print("  기대 sentinel: \(sentinel)")
        print("  실제 파일 내용: '\(got)'")
        print("\n  [\(executed ? "PASS" : "FAIL")] 주입된 명령이 대상 탭에서 실제 실행됨")
        print("  [\(focusKept ? "PASS" : "FAIL")] 주입이 포커스를 뺏지 않음 (최전면 \(frontBefore) 유지)")
        let passes = (executed ? 1 : 0) + (focusKept ? 1 : 0)
        print("\n결과: \(passes) PASS / \(2 - passes) FAIL")
    }

    /// Prints the screen-derived idle/busy state for a tty (verifies the
    /// detector against a real session). Usage: `ClaudeDeck --screen <tty>`.
    static func screenProbe(tty: String) {
        let proc = LiveProcess(id: 0, tty: tty, cwd: nil,
                               termProgram: "Apple_Terminal", termSessionId: nil)
        let state = TerminalActivator.claudeScreenState(proc)
        print("screen \(tty): \(state)")
    }

    /// Drives the REAL screen-driven queue against a REAL live Claude session:
    /// finds the session at `cwd`, queues `count` copies of `text`, arms it, then
    /// runs the production `AppState.runQueueLoop` — which injects one prompt at a
    /// time, gated on the terminal's *visible* idle state — until the queue
    /// drains. Usage: `ClaudeDeck --queue-run <cwd> <count> <text>`.
    @MainActor
    static func queueRun(cwd: String, count: Int, text: String) async {
        print("== 예약 입력 큐 — 화면 기반 구동 (실제 세션) ==\n")
        let scan0 = SessionScanner.scan()
        guard let target = scan0.first(where: { $0.live != nil && $0.cwd == cwd }) else {
            print("  [FAIL] cwd=\(cwd) 에서 라이브 세션을 찾지 못함.")
            for s in scan0 where s.live != nil { print("    - \(s.cwd) (tty=\(s.live?.tty ?? "-"))") }
            return
        }
        let sid = target.id
        let tty = target.live?.tty ?? "-"
        print("  대상 세션: \(target.folderName) | cwd=\(cwd) | tty=\(tty)")

        let settings = AppSettings.shared
        settings.clearQueue(sid)
        for n in 1...max(1, count) { settings.addPrompt("[\(n)] " + text, to: sid) }
        print("  예약 \(count)개 (각 [n] 접두사로 구분)\n")

        let state = AppState()
        state.sessions = scan0          // so runQueueLoop can resolve the live process
        let t0 = Date()
        state.startQueue(sid)           // spawns the loop on its own
        print("  [  0.0s] arm — 화면 유휴 감지 시 하나씩 주입\n")

        // Mirror the loop with our own logging by polling its observable state.
        var lastRemaining = settings.queue(for: sid).count
        let deadline = t0.addingTimeInterval(420)
        while state.isQueueRunning(sid), Date() < deadline {
            let rem = settings.queue(for: sid).count
            if rem != lastRemaining {
                let el = String(format: "%5.1fs", Date().timeIntervalSince(t0))
                print("  [\(el)] ▶︎ 주입됨 — 큐 \(lastRemaining)→\(rem)")
                lastRemaining = rem
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let remaining = settings.queue(for: sid).count
        print("\n  종료: 남은 큐 \(remaining)개, arm=\(state.isQueueRunning(sid))")
        print(remaining == 0 ? "  ✅ 전부 주입 완료 (화면 유휴 감지 기반)."
                             : "  ⚠️ \(remaining)개 미주입 (타임아웃).")
        settings.clearQueue(sid)
    }

    /// Renders the popover (at the given tab) to a PNG so the layout can be
    /// inspected headlessly. Usage: `ClaudeDeck --render <tab> <path> [mock]`.
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
    /// `ClaudeDeck --render dashboard <path> [mock]`.
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
