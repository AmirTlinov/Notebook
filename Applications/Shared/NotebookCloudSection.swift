import SwiftUI

struct NotebookCloudSection: View {
  let model: NotebookAppModel
  @State private var performing = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("Синхронизация iCloud", isOn: Binding(
        get: { model.cloudStatus.enabled },
        set: { enabled in
          performing = true
          Task {
            if enabled { await model.enableCloud() } else { await model.disableCloud() }
            performing = false
          }
        }))
        .disabled(performing || model.accountConnection?.account == nil)
        .accessibilityIdentifier("notebook.cloud.enabled")
      Text(model.cloudStatus.message).font(.callout).foregroundStyle(.secondary)
        .accessibilityIdentifier("notebook.cloud.status")
      Text("Материалы доступны на ваших устройствах. Выключение не удаляет сохранённое.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}
