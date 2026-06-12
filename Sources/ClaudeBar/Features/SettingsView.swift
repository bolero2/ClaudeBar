import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

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
