import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared
    /// Compact-template editing is a dashboard-only task; the menu-bar popover
    /// shows them read-only. Keeps the toolbar = quick-glance, dashboard =
    /// management split clear.
    var allowsEditing = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section(L("언어")) {
                    HStack {
                        Text(L("언어")).font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $settings.language) {
                            Text("English").tag("en")
                            Text("한국어").tag("ko")
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }

                section(L("알림")) {
                    toggle(L("입력 대기 알림"), $settings.notifyWaiting)
                    toggle(L("컨텍스트 임박 알림"), $settings.notifyContext)
                    toggle(L("사용 한도 임박 알림"), $settings.notifyRateLimit)
                }

                section(L("임계치")) {
                    slider(L("컨텍스트 경고"), value: $settings.contextWarnPercent,
                           range: 50...95, unit: "%")
                    slider(L("사용 한도 경고"), value: $settings.rateWarnPercent,
                           range: 50...99, unit: "%")
                }

                section(L("터미널")) {
                    HStack {
                        Text(L("새 세션 / 복구에 사용"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $settings.preferredTerminal) {
                            Text(L("자동")).tag("auto")
                            Text("Terminal").tag("Terminal")
                            Text("iTerm").tag("iTerm")
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }

                section(L("원격 호스트")) {
                    RemoteHostsEditor(settings: settings)
                }

                section(L("compact 템플릿")) {
                    if allowsEditing {
                        CompactTemplatesEditor(settings: settings)
                    } else {
                        CompactTemplatesReadOnly(settings: settings)
                    }
                }

                section(L("앱 업데이트")) {
                    HStack {
                        Text(L("현재 버전")).font(.system(size: 12))
                        Spacer()
                        Text(UpdateService.currentVersion)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    toggle(L("실행 시 업데이트 확인"), $settings.autoCheckUpdates)
                    Button {
                        state.checkForUpdates(userInitiated: true)
                    } label: {
                        HStack(spacing: 6) {
                            if state.isCheckingUpdate {
                                ProgressView().controlSize(.mini)
                            }
                            Text(state.isCheckingUpdate ? L("확인 중…") : L("지금 업데이트 확인"))
                                .font(.system(size: 12))
                        }
                    }
                    .disabled(state.isCheckingUpdate)
                }

                section(L("시스템")) {
                    Toggle(L("로그인 시 자동 실행"), isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    ))
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    private func toggle(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(label, isOn: binding)
            .font(.system(size: 12))
            .toggleStyle(.switch)
            .controlSize(.mini)
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12))
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))\(unit)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// Registers SSH hosts to probe for remote claude sessions. Lists `~/.ssh/config`
/// aliases (toggle to enable) plus any manually-added hosts, and a field to add a
/// host that isn't in the config. Enabling a host makes the next refresh discover
/// every claude session on it.
private struct RemoteHostsEditor: View {
    @ObservedObject var settings: AppSettings
    @State private var newHost = ""

    var body: some View {
        let aliases = SSHConfig.hostAliases()
        let manual = settings.remoteHosts.filter { !aliases.contains($0) }
        VStack(alignment: .leading, spacing: 8) {
            Text(L("켜면 새로고침마다 그 호스트의 claude 세션을 SSH로 조회해 목록에 표시합니다."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if aliases.isEmpty && manual.isEmpty {
                Text(L("~/.ssh/config 에 호스트가 없습니다. 아래에서 직접 추가하세요."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(aliases + manual, id: \.self) { host in
                Toggle(host, isOn: Binding(
                    get: { settings.isRemoteHostEnabled(host) },
                    set: { settings.setRemoteHost(host, enabled: $0) }
                ))
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            HStack(spacing: 6) {
                TextField(L("호스트 별칭 또는 user@host"), text: $newHost)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button(L("추가")) {
                    settings.setRemoteHost(newHost, enabled: true)
                    newHost = ""
                }
                .font(.system(size: 12))
                .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Read-only template list for the menu-bar popover — editing happens in the
/// dashboard so the toolbar stays a quick-glance surface.
private struct CompactTemplatesReadOnly: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.compactTemplates.isEmpty {
                Text(L("저장된 템플릿이 없습니다."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.compactTemplates) { template in
                    HStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(template.name).font(.system(size: 12))
                        Spacer()
                    }
                }
            }
            Text(L("편집은 대시보드에서 가능합니다."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Editable list of saved `/compact` templates, surfaced in each session's
/// right-click → Compact menu.
private struct CompactTemplatesEditor: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(settings.compactTemplates) { template in
                CompactTemplateRow(template: template, settings: settings)
            }
            Button {
                settings.addCompactTemplate(name: L("새 템플릿"), prompt: "")
            } label: {
                Label(L("새 템플릿 추가"), systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Text(L("세션 우클릭 → 압축에서 사용합니다."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct CompactTemplateRow: View {
    let template: CompactTemplate
    @ObservedObject var settings: AppSettings
    @State private var name: String
    @State private var prompt: String

    init(template: CompactTemplate, settings: AppSettings) {
        self.template = template
        self.settings = settings
        _name = State(initialValue: template.name)
        _prompt = State(initialValue: template.prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField(L("이름"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onChange(of: name) { _ in commit() }
                Button {
                    settings.deleteCompactTemplate(template.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            TextEditor(text: $prompt)
                .font(.system(size: 10))
                .frame(height: 46)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.1)))
                .onChange(of: prompt) { _ in commit() }
        }
        .padding(6)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(6)
    }

    private func commit() {
        settings.updateCompactTemplate(
            CompactTemplate(id: template.id, name: name, prompt: prompt))
    }
}
