import SwiftUI

struct AccountView: View {
    @EnvironmentObject var state: AppState
    var scroll = true

    var body: some View {
        if scroll { ScrollView { content } } else { content }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 8) {
                if let account = state.account {
                    AccountCard(account: account)
                } else {
                    EmptyHint(text: "연동된 계정이 없습니다.")
                }

                Text("멀티 계정 전환은 다음 버전에서 지원됩니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }
            .padding(8)
    }
}

private struct AccountCard: View {
    let account: Account
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.displayName ?? account.email)
                            .font(.system(size: 13, weight: .semibold))
                        if account.isActive {
                            Text("활성")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green)
                                .clipShape(Capsule())
                        }
                    }
                    Text(account.email)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            infoRow("조직", account.organizationName)
            infoRow("역할", account.organizationRole)
            infoRow("결제", account.billingType)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .medium))
            }
        }
    }
}
