import SwiftUI
import NotebookCore

/// A status/settings surface, not a prerequisite to using Notebook.
struct NotebookDevicesContent: View {
  let model: NotebookAppModel
  @State private var relayPeer: NotebookTransportIdentity?
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
          Text(model.deviceIsConnected(peer.deviceID) ? "Подключено " + (model.deviceRouteTitle(peer.deviceID) ?? "") : model.deviceConnectsAutomatically(peer.deviceID) ? "Не в сети" : "Отключено")
            .foregroundStyle(.secondary)
        }
        .contextMenu {
          #if os(macOS)
          Button("Интернет-доступ…") { relayPeer = peer }.disabled(!model.deviceConnectsAutomatically(peer.deviceID))
          #endif
          Button(model.deviceConnectsAutomatically(peer.deviceID) ? "Не подключаться автоматически" : "Подключаться автоматически") {
            Task { await model.setDeviceAutomatic(peer.deviceID, allowed: !model.deviceConnectsAutomatically(peer.deviceID)) }
          }.disabled(!model.canChangeDeviceConnections)
        }
      }
    } footer: {
      Text("Ваши устройства с одним Apple Account подключаются сами. Mac нужен для работы с Codex; писать можно и без него.")
    }
    Section { NotebookCloudSection(model: model) }
    #if os(macOS)
      .sheet(isPresented: Binding(get: { relayPeer != nil }, set: { if !$0 { relayPeer = nil } })) {
        if let peer = relayPeer { NotebookRelaySettingsView(model: model, peer: peer) }
      }
    #endif
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
