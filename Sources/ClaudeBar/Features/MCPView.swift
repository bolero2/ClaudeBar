import SwiftUI

struct MCPView: View {
    @EnvironmentObject var state: AppState
    var scroll = true

    var body: some View {
        if scroll { ScrollView { content } } else { content }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "전역 MCP", count: state.globalMCP.count)
                if state.globalMCP.isEmpty {
                    EmptyHint(text: "전역 MCP 서버가 없습니다.")
                } else {
                    ForEach(state.globalMCP) { server in
                        MCPRow(server: server)
                    }
                }

                let grouped = Dictionary(grouping: state.projectMCP) { $0.projectPath ?? "" }
                if !grouped.isEmpty {
                    SectionHeader(title: "프로젝트별 MCP", count: grouped.count)
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
            }
            .padding(8)
    }
}

private struct MCPRow: View {
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
            Text(server.enabled ? "활성" : "비활성")
                .font(.system(size: 10))
                .foregroundStyle(server.enabled ? .green : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
