import SwiftUI
import NotebookCore

/// A status/settings surface, not a prerequisite to using Notebook.
struct NotebookDevicesContent: View {
  let model: NotebookAppModel
  var body: some View {
    Section {
      if model.awaitingAccountContent {
        ProgressView("Открываем ваши материалы…")
      }
      Label(model.deviceStatusMessage, systemImage: model.isPeerConnected ? "checkmark.circle" : "laptopcomputer.and.ipad")
        .accessibilityIdentifier("notebook.devices.status")
      ForEach(model.knownDevices, id: \.deviceID) { peer in
        HStack {
          Text(peer.displayName)
          Spacer()
          Text(model.deviceIsConnected(peer.deviceID) ? "Подключено" : model.deviceConnectsAutomatically(peer.deviceID) ? "Не в сети" : "Отключено")
            .foregroundStyle(.secondary)
        }
        .contextMenu {
          Button(model.deviceConnectsAutomatically(peer.deviceID) ? "Не подключаться автоматически" : "Подключаться автоматически") {
            Task { await model.setDeviceAutomatic(peer.deviceID, allowed: !model.deviceConnectsAutomatically(peer.deviceID)) }
          }.disabled(!model.canChangeDeviceConnections)
        }
      }
    } footer: {
      Text("Ваши устройства с одним Apple Account подключаются сами. Mac нужен для работы с Codex; писать можно и без него.")
    }
    Section { NotebookCloudSection(model: model) }
  }
}

#if os(iOS)
struct NotebookDevicesView: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form { NotebookDevicesContent(model: model) }
        .navigationTitle("Устройства")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
    }
  }
}
#endif
