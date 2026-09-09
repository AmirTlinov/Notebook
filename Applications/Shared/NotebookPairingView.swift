import SwiftUI
import NotebookCore

#if os(iOS)
/// Pairing is a deliberate device/workspace approval, not discovery-based trust.
struct NotebookPairingView: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var invitation = ""
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("Подключение к Mac") {
          switch model.pairingState {
          case .idle:
            Text("На Mac откройте Notebook в строке меню и скопируйте приглашение. Оба устройства должны использовать один перенесённый рабочий архив.")
            TextField("Приглашение Notebook", text: $invitation, axis: .vertical)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("pairing-invitation")
            Button("Подключиться") { perform { try model.joinPairingInvitation(invitation) } }
              .disabled(invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          case .invitation:
            Text("Приглашение создано на Mac. До подтверждения на обоих устройствах содержание не передаётся.")
          case .connecting:
            HStack { ProgressView(); Text("Ожидается защищённое соединение…") }
          case .confirmation(let peer, let generation, let locallyConfirmed):
            Text(peer.displayName).font(.headline)
            LabeledContent("Устройство", value: peer.deviceID.uuidString.lowercased())
              .font(.caption).textSelection(.enabled)
            LabeledContent("Архив", value: peer.workspaceID.uuidString.lowercased())
              .font(.caption).textSelection(.enabled)
            Text("Сверьте это устройство и архив с Mac. Имя само по себе не подтверждает подлинность.")
            if locallyConfirmed { Text("Вы подтвердили. Ожидается подтверждение на Mac.") }
            else { Button("Разрешить этому Mac доступ") { perform { try model.confirmPairing(generation: generation) } } }
          case .paired(let peer):
            Label("Подключено: \(peer.displayName)", systemImage: "checkmark.shield")
          case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("Начать заново") { perform { try model.cancelPairing() } }
          }
          if case .idle = model.pairingState {} else {
            Button("Отменить сопряжение", role: .cancel) { perform { try model.cancelPairing() } }
          }
        }
        if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("pairing-error") } }
        if !model.pairedPeers.isEmpty {
          Section("Доверенные устройства") {
            ForEach(model.pairedPeers, id: \.deviceID) { peer in
              VStack(alignment: .leading, spacing: 8) {
                Text(peer.displayName)
                Button("Отозвать доступ", role: .destructive) { perform { try model.revokePeer(peer.deviceID) } }
              }
            }
          }
        }
      }
      .navigationTitle("Соединение")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
    }
  }

  private func perform(_ operation: () throws -> Void) {
    do { try operation(); error = nil }
    catch NotebookTransportError.identityMismatch {
      error = "Приглашение относится к другому устройству или архиву. Сначала перенесите согласованный checkpoint; существующие данные не будут заменены автоматически."
    } catch NotebookTransportError.pairingExpired {
      error = "Приглашение истекло. Создайте новое на Mac."
    } catch { self.error = "Сопряжение не завершено: \(error.localizedDescription)" }
  }
}

#endif
