import SwiftUI

struct MCPView: View {
    @EnvironmentObject var state: AppState
    var scroll = true

    var body: some View {
        if scroll { ScrollView { content } } else { content }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: L("전역 MCP"), count: state.globalMCP.count)
                if state.globalMCP.isEmpty {
                    EmptyHint(text: L("전역 MCP 서버가 없습니다."))
                } else {
                    ForEach(state.globalMCP) { server in
                        MCPRow(server: server)
                    }
                }

                let grouped = Dictionary(grouping: state.projectMCP) { $0.projectPath ?? "" }
                if !grouped.isEmpty {
                    SectionHeader(title: L("프로젝트별 MCP"), count: grouped.count)
                    ForEach(grouped.keys.sorted(), id: \.self) { path in
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 4)
                        ForEach(grouped[path] ?? []) { server in
                            MCPRow(server: server)
                        }
                    }
                }

                Text(L("토글은 새로 시작하는 세션부터 적용됩니다. (실행 중 세션은 영향 없음)"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }
            .padding(8)
    }
}

/// A compact on/off switch drawn with plain shapes so it renders consistently
/// (incl. in offscreen ImageRenderer screenshots, unlike a native `Toggle`).
private struct MiniSwitch: View {
    let isOn: Bool
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 30, height: 18)
            Circle()
                .fill(.white)
                .frame(width: 14, height: 14)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

private struct MCPRow: View {
    @EnvironmentObject var state: AppState
    let server: MCPServerInfo
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(server.enabled ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.system(size: 12, weight: .medium))
                    Text(server.transport)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(3)
                }
                Text(server.command)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if server.toggleable {
                Button { state.toggleMCP(server) } label: {
                    MiniSwitch(isOn: server.enabled)
                }
                .buttonStyle(.plain)
                .help(server.enabled ? L("클릭: 끄기") : L("클릭: 켜기"))
            } else {
                Text(L("항상 켜짐"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
