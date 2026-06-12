import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case sessions, usage, mcp, account
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: return "세션"
        case .usage: return "사용량"
        case .mcp: return "MCP"
        case .account: return "계정"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: return "terminal"
        case .usage: return "chart.bar.fill"
        case .mcp: return "puzzlepiece.extension.fill"
        case .account: return "person.crop.circle"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var tab: Tab

    init(initialTab: Tab = .sessions) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()

            Group {
                switch tab {
                case .sessions: SessionListView()
                case .usage: UsageView()
                case .mcp: MCPView()
                case .account: AccountView()
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 380, height: 500)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .foregroundStyle(.tint)
            Text("Claude Bar")
                .font(.system(size: 13, weight: .semibold))
            if state.liveSessionCount > 0 {
                Text("\(state.liveSessionCount) 실행 중")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            }
            if state.contextWarning {
                Label("컨텍스트 \(Int(state.peakLiveContextFraction * 100))%",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            Button {
                state.newSessionInteractive()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("새 세션 시작 (디렉토리 선택)")
            Button {
                state.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(state.isRefreshing ? 360 : 0))
                    .animation(state.isRefreshing
                               ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                               : .default, value: state.isRefreshing)
            }
            .buttonStyle(.plain)
            .help("새로고침")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.symbol).font(.system(size: 12))
                        Text(t.title).font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(tab == t ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            if let last = state.lastRefresh {
                Text("업데이트 \(Format.ago(last))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("종료").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
