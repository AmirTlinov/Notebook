import SwiftUI

struct NotebookCloudSection: View {
  let model: NotebookAppModel
  @State private var confirming = false
  @State private var performing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("CloudKit · личная тетрадь", systemImage: "icloud")
        .font(.headline)
      Text(model.cloudStatus.message).font(.callout).foregroundStyle(.secondary)
        .accessibilityIdentifier("notebook.cloud.status")
      if model.cloudStatus.enabled {
        HStack {
          Button("Обменяться сейчас") { perform { await model.syncCloudNow() } }
          Button("Выключить") { perform { await model.disableCloud() } }
        }
      } else {
        Button("Включить CloudKit…") { confirming = true }
          .accessibilityIdentifier("notebook.cloud.enable")
      }
      Text("Один Apple Account и одно пространство на обоих устройствах. Интернет и Mac не нужны для локального сохранения. Облако не переносит чат, голос или терминал.")
        .font(.caption).foregroundStyle(.secondary)
      if performing { ProgressView().controlSize(.small) }
    }
    .disabled(performing)
    .confirmationDialog("Отправить эту тетрадь в текущий Apple Account?", isPresented: $confirming, titleVisibility: .visible) {
      Button("Включить и отправить тетрадь") { perform { await model.enableCloud() } }
      Button("Отмена", role: .cancel) {}
    } message: {
      Text("CloudKit сохранит содержание в приватной базе iCloud. Если аккаунт изменился, эта кнопка явно разрешает отправить ему локальную тетрадь. Выключение не удаляет локальные или облачные материалы.")
    }
  }

  private func perform(_ action: @escaping @MainActor () async -> Void) {
    performing = true
    Task { await action(); performing = false }
  }
}
