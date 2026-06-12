import SwiftUI

enum SessionFilter: String, CaseIterable, Identifiable {
    case all, live, ended
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "전체"
        case .live: return "실행 중"
        case .ended: return "종료"
        }
    }
}

struct SessionListView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared
    @State private var query = ""
    @State private var filter: SessionFilter = .all
    var scroll = true
    /// Dashboard passes true to allow inline prompt-queue editing; the toolbar
    /// keeps it read-only.
    var queueEditable = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if scroll {
                ScrollView { content }
            } else {
                content
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 6) {
            // `scroll == false` is the offscreen screenshot path; a TextField
            // renders as a placeholder box there, so skip it.
            if scroll {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(L("프로젝트 검색"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(SessionFilter.allCases) { f in
                    Button { filter = f } label: {
                        Text(L(f.title))
                            .font(.system(size: 11, weight: filter == f ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(filter == f ? Color.accentColor.opacity(0.18) : Color.clear)
                            .foregroundStyle(filter == f ? Color.accentColor : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(8)
    }

    private func matches(_ s: Session) -> Bool {
        let q = query.lowercased()
        let textOK = q.isEmpty
            || s.folderName.lowercased().contains(q)
            || s.cwd.lowercased().contains(q)
        let statusOK: Bool
        switch filter {
        case .all: statusOK = true
        case .live: statusOK = s.live != nil
        case .ended: statusOK = s.live == nil
        }
        return textOK && statusOK
    }

    private var content: some View {
        let filtered = state.sessions.filter(matches)
        let pinned = filtered.filter { settings.isPinned($0.projectDirName) }
        let live = filtered.filter { $0.live != nil && !settings.isPinned($0.projectDirName) }
        let recent = filtered.filter { $0.live == nil && !settings.isPinned($0.projectDirName) }.prefix(20)

        return VStack(alignment: .leading, spacing: 4) {
            if pinned.isEmpty && live.isEmpty && recent.isEmpty {
                EmptyHint(text: query.isEmpty ? L("세션을 찾을 수 없습니다.") : L("검색 결과가 없습니다."))
            }
            if !pinned.isEmpty {
                SectionHeader(title: L("즐겨찾기"), count: nil)
                ForEach(pinned) { SessionRow(session: $0, queueEditable: queueEditable) }
            }
            if !live.isEmpty {
                SectionHeader(title: L("실행 중"), count: live.count)
                ForEach(live) { SessionRow(session: $0, queueEditable: queueEditable) }
            }
            if !recent.isEmpty {
                SectionHeader(title: L("최근 세션"), count: nil)
                ForEach(Array(recent)) { SessionRow(session: $0, queueEditable: queueEditable) }
            }
        }
        .padding(8)
    }
}

private struct SessionRow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared
    let session: Session
    var queueEditable = false
    @State private var hovering = false
    @State private var showQueue = false

    private var pinned: Bool { settings.isPinned(session.projectDirName) }

    /// A compact badge for non-default permission modes.
    private var modeBadge: (text: String, color: Color)? {
        switch session.permissionMode {
        case "plan": return ("PLAN", .blue)
        case "acceptEdits": return ("ACCEPT", .orange)
        case "bypassPermissions": return ("BYPASS", .red)
        default: return nil
        }
    }

    /// Recent (ended) rows are muted to grayscale until hovered.
    private var muted: Bool { session.live == nil && !hovering }

    var body: some View {
        VStack(spacing: 0) {
        Button {
            state.activate(session)
        } label: {
            VStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: session.status.symbol)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 10))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if pinned {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                        }
                        Text(session.folderName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .layoutPriority(1)           // keep the name; truncate branch first
                        // Branch on a single line; truncate with … only if too long.
                        if let branch = session.gitBranch, branch != "HEAD" {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Text(session.cwd)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)

                    if session.live != nil, let activity = session.activity {
                        HStack(spacing: 4) {
                            Image(systemName: session.status == .busy
                                  ? "play.fill" : "quote.bubble")
                                .font(.system(size: 8))
                            Text(activity)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(session.status == .busy ? Color.green : Color.secondary)
                    }
                }

                Spacer(minLength: 6)

                // Model / time, with the permission-mode badge pinned at the far right.
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        if let mode = modeBadge {
                            Text(mode.text)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(mode.color)
                                .clipShape(Capsule())
                        }
                        Text(Format.model(session.model))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(Format.ago(session.lastActivity))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .fixedSize()
            }

            if let fraction = session.contextFraction, let tokens = session.contextTokens {
                ContextBar(fraction: fraction, tokens: tokens, limit: session.contextLimit)
                    .padding(.leading, 22)
            }

            // Toolbar shows the queue read-only; the dashboard edits it below.
            if !queueEditable, session.live != nil {
                PromptQueueBadge(session: session)
                    .padding(.leading, 22)
            }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        // Dashboard-only queue editor, outside the activate button so its
        // controls (text field, buttons) aren't swallowed by the row tap.
        if queueEditable, session.live != nil {
            queueArea
        }
        }
        .background(rowBackground)
        .cornerRadius(6)
        .grayscale(muted ? 1.0 : 0.0)
        .opacity(muted ? 0.55 : 1.0)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .help(session.live != nil
              ? L("클릭: 해당 터미널 탭을 앞으로")
              : L("클릭: 새 터미널에서 이 세션 복구 (claude --resume)"))
        .contextMenu {
            Button(pinned ? L("즐겨찾기 제거") : L("즐겨찾기 추가")) {
                settings.togglePin(session.projectDirName)
            }
            Divider()
            if session.live != nil {
                Button(L("터미널 앞으로")) { state.activate(session) }
                Menu(L("압축 (/compact)")) {
                    Button(L("기본 압축")) { state.compact(session) }
                    if !settings.compactTemplates.isEmpty {
                        Divider()
                        ForEach(settings.compactTemplates) { t in
                            Button(t.name) { state.compact(session, prompt: t.prompt) }
                        }
                    }
                    Divider()
                    Button(L("직접 입력…")) { state.compactWithCustomPrompt(session) }
                }
                Button(L("대화 비우기 (/clear)")) { state.clearSession(session) }
                Button(L("세션 종료 (kill)"), role: .destructive) { state.killSession(session) }
            } else {
                Button(L("새 터미널에서 복구")) { state.activate(session) }
            }
            Divider()
            Button(L("Finder에서 열기")) { state.revealInFinder(session.cwd) }
            Button(L("경로 복사")) { state.copyPath(session.cwd) }
        }
    }

    /// Collapsible "예약 입력" area shown under live rows in the dashboard.
    private var queueArea: some View {
        let count = settings.queue(for: session.id).count
        let running = state.isQueueRunning(session.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button { showQueue.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: showQueue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
                    Text(L("예약 입력")).font(.system(size: 11, weight: .medium))
                    if count > 0 {
                        Text("(\(count))").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if running {
                        Text(L("실행 중"))
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.green.opacity(0.2)).clipShape(Capsule())
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showQueue {
                PromptQueueEditor(session: session)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .padding(.leading, 12)
    }

    private var rowBackground: Color {
        if session.live != nil { return Color.accentColor.opacity(0.08) }
        return hovering ? Color.primary.opacity(0.06) : Color.clear
    }

    private var statusColor: Color {
        switch session.status {
        case .busy: return .green
        case .waiting: return .orange
        case .inactive: return .secondary
        }
    }
}

/// Per-session context-window usage: a thin fill bar plus "used / window · %".
private struct ContextBar: View {
    let fraction: Double
    let tokens: Int
    let limit: Int

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 4)

            Text("\(Format.tokens(tokens)) / \(SessionContext.windowLabel(limit)) · \(Int(fraction * 100))%")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .help("\(L("컨텍스트")): \(tokens.formatted()) / \(limit.formatted()) \(L("토큰"))")
    }

    private var color: Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int?
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.2))
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }
}
