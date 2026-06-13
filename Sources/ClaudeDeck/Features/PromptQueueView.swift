import SwiftUI

/// Dashboard-only editor for a live session's scheduled-prompt queue: add,
/// reorder, delete prompts, and arm/disarm auto-injection.
struct PromptQueueEditor: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared
    let session: Session
    @State private var draft = ""
    /// Id of the prompt currently being edited inline (nil = none), plus its
    /// working text. Editing is dashboard-only and blocked while injecting.
    @State private var editingId: String?
    @State private var editDraft = ""

    private var queue: [ScheduledPrompt] { settings.queue(for: session.id) }
    private var running: Bool { state.isQueueRunning(session.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if queue.isEmpty {
                Text(L("예약된 프롬프트가 없습니다."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(queue.enumerated()), id: \.element.id) { idx, prompt in
                    HStack(alignment: .top, spacing: 4) {
                        Text("\(idx + 1).")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        if editingId == prompt.id {
                            TextField(L("프롬프트 수정…"), text: $editDraft, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .lineLimit(1...4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onSubmit(saveEdit)
                            Button { saveEdit() } label: {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                            .buttonStyle(.plain)
                            .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button { cancelEdit() } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(prompt.text)
                                .font(.system(size: 11))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { beginEdit(prompt) } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain).disabled(running).help(L("수정"))
                            Button { settings.movePrompt(in: session.id, from: idx, to: idx - 1) } label: {
                                Image(systemName: "arrow.up")
                            }
                            .buttonStyle(.plain).disabled(idx == 0 || running)
                            Button { settings.movePrompt(in: session.id, from: idx, to: idx + 1) } label: {
                                Image(systemName: "arrow.down")
                            }
                            .buttonStyle(.plain).disabled(idx == queue.count - 1 || running)
                            Button { settings.removePrompt(prompt.id, from: session.id) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain).disabled(running)
                        }
                    }
                    .font(.system(size: 10))
                }
            }

            HStack(spacing: 6) {
                TextField(L("프롬프트 추가…"), text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .lineLimit(1...4)
                    .onSubmit(add)
                Button(L("추가")) { add() }
                    .font(.system(size: 11))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                if running {
                    Button { state.stopQueue(session.id) } label: {
                        Label(L("정지"), systemImage: "stop.fill").font(.system(size: 11))
                    }
                    .foregroundStyle(.orange)
                    Text(L("실행 중 · 유휴 시 다음 프롬프트 자동 입력"))
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                } else {
                    Button { state.startQueue(session.id) } label: {
                        Label(L("시작"), systemImage: "play.fill").font(.system(size: 11))
                    }
                    .disabled(queue.isEmpty)
                    if !queue.isEmpty {
                        Text("\(queue.count)\(L("개 대기"))")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !queue.isEmpty && !running {
                    Button(L("비우기")) { settings.clearQueue(session.id) }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        settings.addPrompt(text, to: session.id)
        draft = ""
    }

    private func beginEdit(_ prompt: ScheduledPrompt) {
        editingId = prompt.id
        editDraft = prompt.text
    }

    private func saveEdit() {
        guard let id = editingId else { return }
        let text = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        settings.updatePrompt(id, text: text, in: session.id)
        cancelEdit()
    }

    private func cancelEdit() {
        editingId = nil
        editDraft = ""
    }
}

/// Read-only queue summary for the menu-bar popover (toolbar shows, doesn't edit).
struct PromptQueueBadge: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared
    let session: Session

    var body: some View {
        let queue = settings.queue(for: session.id)
        if !queue.isEmpty {
            let running = state.isQueueRunning(session.id)
            HStack(spacing: 4) {
                Image(systemName: running ? "clock.badge.checkmark.fill" : "clock")
                    .font(.system(size: 9))
                Text("\(L("예약")) \(queue.count)" + (running ? " · \(L("실행 중"))" : ""))
                    .font(.system(size: 9, weight: .medium))
                if let next = queue.first {
                    Text("· \(next.text)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .foregroundStyle(running ? Color.green : Color.secondary)
        }
    }
}
