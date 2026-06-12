import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case sessions, usage, mcp, account, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: return "세션"
        case .usage: return "사용량"
        case .mcp: return "MCP"
        case .account: return "계정"
        case .settings: return "설정"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: return "terminal"
        case .usage: return "chart.bar.fill"
        case .mcp: return "puzzlepiece.extension.fill"
        case .account: return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared
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
                case .settings: SettingsView(allowsEditing: false)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 380, height: 500)
        .id(settings.language)   // rebuild whole tree when language changes
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .foregroundStyle(.tint)
            Text("ClaudeDeck")
                .font(.system(size: 13, weight: .semibold))
            if state.liveSessionCount > 0 {
                Text("\(state.liveSessionCount) \(L("실행 중"))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            }
            if state.contextWarning {
                Label("\(L("컨텍스트")) \(Int(state.peakLiveContextFraction * 100))%",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            Button {
                state.onOpenDashboard?()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.plain)
            .help(L("대시보드 열기"))
            NewSessionButton()
            .help(L("새 세션 시작 (디렉토리 선택)"))
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
            .help(L("새로고침"))
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
                        Text(L(t.title)).font(.system(size: 10))
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

    @ViewBuilder private func NewSessionButton() -> some View {
        Menu {
            Button(L("새 세션")) { state.newSessionInteractive() }
            Button(L("새 세션 · 권한 건너뛰기")) {
                state.newSessionInteractive(skipPermissions: true)
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var footer: some View {
        HStack {
            if let last = state.lastRefresh {
                Text("\(L("업데이트")) \(Format.ago(last))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text(L("끝내기")).font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
