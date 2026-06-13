import SwiftUI

struct MCPView: View {
    @EnvironmentObject var state: AppState
    @State private var showAdd = false
    var scroll = true

    var body: some View {
        if scroll { ScrollView { content } } else { content }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L("전역 MCP"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(state.globalMCP.count)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.green.opacity(0.2)).clipShape(Capsule())
                    Spacer()
                    Button { showAdd.toggle() } label: {
                        Label(L("추가"), systemImage: showAdd ? "xmark" : "plus")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)

                if showAdd {
                    MCPAddForm(onClose: { showAdd = false })
                }

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

/// Inline "register a global MCP server" form, used in both the toolbar popover
/// and the dashboard. Supports the two common shapes: a stdio command and a
/// remote http/sse URL. Writes to `~/.claude.json` via `AppState.addGlobalMCP`.
private struct MCPAddForm: View {
    @EnvironmentObject var state: AppState
    let onClose: () -> Void

    enum Transport: String, CaseIterable, Identifiable {
        case stdio, http, sse
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var transport: Transport = .stdio
    @State private var command = ""
    @State private var args = ""
    @State private var env = ""
    @State private var url = ""
    @State private var headers = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field(L("이름"), L("예: filesystem"), $name)

            Picker("", selection: $transport) {
                ForEach(Transport.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if transport == .stdio {
                field(L("명령어"), "npx", $command)
                multiField(L("인자"), L("한 줄에 하나 (또는 공백 구분)"), $args)
                multiField(L("환경변수 (선택)"), "KEY=VALUE", $env)
            } else {
                field("URL", "https://…", $url)
                multiField(L("헤더 (선택)"), "Authorization: Bearer …", $headers)
            }

            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L("취소")) { onClose() }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                Button(L("등록")) { submit() }
                    .font(.system(size: 11, weight: .medium))
                    .disabled(!canSubmit)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var canSubmit: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTarget = transport == .stdio
            ? !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && hasTarget
    }

    private func submit() {
        var config: [String: Any] = [:]
        if transport == .stdio {
            config["command"] = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = Self.parseArgs(args)
            if !parsed.isEmpty { config["args"] = parsed }
            let e = Self.parsePairs(env, separator: "=")
            if !e.isEmpty { config["env"] = e }
        } else {
            config["type"] = transport.rawValue
            config["url"] = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let h = Self.parsePairs(headers, separator: ":")
            if !h.isEmpty { config["headers"] = h }
        }
        if let err = state.addGlobalMCP(name: name, config: config) {
            error = err
        } else {
            onClose()
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
        }
    }

    @ViewBuilder
    private func multiField(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                .lineLimit(1...4)
        }
    }

    /// Splits args one-per-line; a single line is split on whitespace so a pasted
    /// command line ("-y @scope/pkg") also works. Empty tokens are dropped.
    static func parseArgs(_ raw: String) -> [String] {
        let lines = raw.split(whereSeparator: \.isNewline).map { String($0) }
        let tokens: [String]
        if lines.count <= 1 {
            tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        } else {
            tokens = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return tokens.filter { !$0.isEmpty }
    }

    /// Parses "KEY<sep>VALUE" lines (split on the first separator) into a dict.
    static func parsePairs(_ raw: String, separator: Character) -> [String: String] {
        var out: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let idx = line.firstIndex(of: separator) else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
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
