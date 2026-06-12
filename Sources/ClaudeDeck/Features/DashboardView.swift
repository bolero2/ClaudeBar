import SwiftUI

/// The full-window "dashboard" (Docker-Desktop style): a sidebar of the same
/// tabs as the menu-bar popover, but with room for the heavier views (usage
/// charts, per-project breakdown, settings). Shares the one `AppState`, so it's
/// always in sync with the popover.
struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared
    @State private var tab: Tab
    /// When true, uses the scroll-less view variants so `ImageRenderer` can
    /// capture the layout (for mock README screenshots).
    private let screenshot: Bool

    init(initialTab: Tab = .sessions, screenshot: Bool = false) {
        _tab = State(initialValue: initialTab)
        self.screenshot = screenshot
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 196)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 520)
        .id(settings.language)   // rebuild on language change
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(.tint)
                Text("ClaudeDeck").font(.system(size: 14, weight: .semibold))
                Spacer()
                NewSessionMenu()
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    HStack(spacing: 8) {
                        Image(systemName: t.symbol).frame(width: 18)
                        Text(L(t.title)).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(tab == t ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundStyle(tab == t ? Color.accentColor : Color.primary)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                if state.liveSessionCount > 0 {
                    Label("\(state.liveSessionCount) \(L("실행 중"))", systemImage: "circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
                if state.contextWarning {
                    Label("\(L("컨텍스트")) \(Int(state.peakLiveContextFraction * 100))%",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
                HStack(spacing: 8) {
                    Button { state.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(state.isRefreshing ? 360 : 0))
                            .animation(state.isRefreshing
                                       ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                       : .default, value: state.isRefreshing)
                    }
                    .buttonStyle(.plain)
                    .help(L("새로고침"))
                    if let last = state.lastRefresh {
                        Text("\(L("업데이트")) \(Format.ago(last))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder private var detail: some View {
        switch tab {
        case .sessions: SessionListView(scroll: !screenshot)
        case .usage: UsageView(scroll: !screenshot)
        case .mcp: MCPView(scroll: !screenshot)
        case .account: AccountView(scroll: !screenshot)
        case .settings: SettingsView()
        }
    }

    @ViewBuilder private func NewSessionMenu() -> some View {
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
        .help(L("새 세션 시작 (디렉토리 선택)"))
    }
}
