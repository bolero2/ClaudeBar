import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var state: AppState
    var scroll = true

    var body: some View {
        if scroll {
            ScrollView { content }
        } else {
            content
        }
    }

    private var content: some View {
        let live = state.sessions.filter { $0.live != nil }
        let recent = state.sessions.filter { $0.live == nil }.prefix(20)

        return VStack(alignment: .leading, spacing: 4) {
            if live.isEmpty && recent.isEmpty {
                EmptyHint(text: "세션을 찾을 수 없습니다.")
            }

            if !live.isEmpty {
                SectionHeader(title: "실행 중", count: live.count)
                ForEach(live) { session in
                    SessionRow(session: session)
                }
            }

            if !recent.isEmpty {
                SectionHeader(title: "최근 세션", count: nil)
                ForEach(Array(recent)) { session in
                    SessionRow(session: session)
                }
            }
        }
        .padding(8)
    }
}

private struct SessionRow: View {
    @EnvironmentObject var state: AppState
    let session: Session
    @State private var hovering = false

    /// Recent (ended) rows are muted to grayscale until hovered.
    private var muted: Bool { session.live == nil && !hovering }

    var body: some View {
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
                        Text(session.folderName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let branch = session.gitBranch, branch != "HEAD" {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    Text(session.cwd)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.model(session.model))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(Format.ago(session.lastActivity))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            if let fraction = session.contextFraction, let tokens = session.contextTokens {
                ContextBar(fraction: fraction, tokens: tokens, limit: session.contextLimit)
                    .padding(.leading, 22)
            }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .cornerRadius(6)
        .grayscale(muted ? 1.0 : 0.0)
        .opacity(muted ? 0.55 : 1.0)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .help(session.live != nil
              ? "클릭: 해당 터미널 탭을 앞으로"
              : "클릭: 새 터미널에서 이 세션 복구 (claude --resume)")
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
        .help("컨텍스트 사용량: \(tokens.formatted()) / \(limit.formatted()) 토큰")
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
