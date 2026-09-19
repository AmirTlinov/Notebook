import SwiftUI
import NotebookCore

struct NotebookCodexAccountView: View {
  let request: (CodexAccountQuery) async throws -> CodexAccountState
  @Environment(\.dismiss) private var dismiss
  @State private var state: CodexAccountState?
  @State private var failure: String?
  @State private var working = false
  @State private var confirmsLogout = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Codex на выбранном Mac") {
          if let account = state?.account {
            Text(account.email ?? account.type).textSelection(.enabled)
            if let plan = account.plan { Text(plan).foregroundStyle(.secondary) }
          } else { Text("Вход не выполнен") }
          Text("Аккаунт общий с Codex CLI и Desktop на этом Mac. Токены остаются у Codex; iPad их не получает.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        if let login = state?.login {
          Section("Вход по коду") {
            Text(login.userCode).font(.title.monospaced()).textSelection(.enabled)
              .accessibilityIdentifier("codex-account-device-code")
            Link("Открыть официальный вход", destination: login.verificationURL)
            Button("Отменить вход", role: .cancel) { perform(.cancelLogin(id: login.id)) }
          }
        } else if state?.account == nil {
          Button("Войти в ChatGPT") { perform(.beginLogin(attempt: UUID())) }
            .accessibilityIdentifier("codex-account-sign-in")
        }
        if let state, state.account != nil {
          Section("Лимиты") {
            if let limits = state.limits, !limits.isEmpty {
              ForEach(limits) { limit in
                VStack(alignment: .leading, spacing: 4) {
                  Text("\(limit.remainingPercent)% осталось · \(limit.id)")
                  if let minutes = limit.durationMinutes { Text("Окно: \(minutes) мин").font(.caption) }
                  if let reset = limit.resetsAt { Text("Сброс: \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                }
              }
            } else { Text("Лимиты недоступны").foregroundStyle(.secondary) }
          }
          Section {
            Button("Выйти из общего аккаунта", role: .destructive) { confirmsLogout = true }
              .accessibilityIdentifier("codex-account-sign-out")
            Text("Отключить только этот iPad можно в разделе «Устройства». Остановка задачи — отдельное действие.")
              .font(.footnote).foregroundStyle(.secondary)
          }
        }
        if let message = state?.message { Text(message).font(.footnote) }
        if let failure { Text(failure).foregroundStyle(.red).accessibilityIdentifier("codex-account-error") }
        Button("Обновить состояние") { perform(.read) }
      }
      .disabled(working)
      .overlay { if working { ProgressView() } }
      .navigationTitle("Аккаунт Codex")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
      .confirmationDialog("Выйти из Codex на Mac?", isPresented: $confirmsLogout, titleVisibility: .visible) {
        if let state { Button("Выйти", role: .destructive) { perform(.logout(revision: state.revision)) } }
      } message: { Text("Выход затронет общий профиль CLI и Desktop. Сначала завершите активную работу. Материалы и сопряжение Notebook сохранятся.") }
      .task {
        await update(.read)
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(3)) } catch { return }
          if state?.login != nil, !working { await update(.read) }
        }
      }
    }
    .frame(minWidth: 320, minHeight: 400)
  }

  private func perform(_ query: CodexAccountQuery) { Task { await update(query) } }
  @MainActor private func update(_ query: CodexAccountQuery) async {
    guard !working else { return }
    working = true; defer { working = false }
    do { state = try await request(query); failure = nil }
    catch { failure = "Не удалось обновить аккаунт. Показанные сведения могут устареть. \(error.localizedDescription)" }
  }
}
