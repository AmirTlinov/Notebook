import SwiftUI
import NotebookCore

/// A single, reusable window presents the existing model's pairing state.
/// Constructing, showing and closing it never grants access or creates a token.
@MainActor
final class NotebookMacPairingWindowController: NSWindowController {
  init(launch: NotebookApplicationLaunch, retry: @escaping () -> Void) {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 540, height: 500),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "Notebook — Сопряжение"
    window.identifier = .init("notebook.pairing.window")
    window.setAccessibilityIdentifier("notebook.pairing.window")
    window.minSize = .init(width: 480, height: 380)
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.moveToActiveSpace]
    window.contentViewController = NSHostingController(rootView: NotebookMacPairingView(launch: launch, retry: retry))
    window.center()
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Programmatic pairing window") }

  func showPairing() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
  }
}

private struct NotebookMacPairingView: View {
  let launch: NotebookApplicationLaunch
  let retry: () -> Void
  @State private var error: String?
  @State private var performing = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Подключение iPad").font(.title2.weight(.semibold))
        if let model = launch.model {
          connection(model).disabled(performing)
          Divider()
          NotebookCloudSection(model: model)
        } else {
          Text(launch.message).textSelection(.enabled)
          if launch.failure != nil { Button("Повторить проверку", action: retry) }
        }
        if performing { ProgressView("Обновляется подключение…").controlSize(.small) }
        if let error {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
            .accessibilityIdentifier("notebook.pairing.error")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
  }

  @ViewBuilder private func connection(_ model: NotebookAppModel) -> some View {
    Text(model.isPeerConnected ? "iPad подключён" : "Ожидается iPad")
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("notebook.pairing.connection")
    if case .failed(let message) = model.loadState { Text(message).foregroundStyle(.red) }

    VStack(alignment: .leading, spacing: 10) {
      Button("Скопировать приглашение для iPad") {
        perform {
          let invitation = try await model.createPairingInvitation()
          NSPasteboard.general.clearContents()
          guard NSPasteboard.general.setString(invitation, forType: .string) else {
            throw NotebookTransportError.storageUnavailable
          }
        }
      }
      .accessibilityIdentifier("notebook.pairing.copy-invitation")
      Text("На iPad откройте «Подключение и устройства» и вставьте приглашение.")
        .font(.callout).foregroundStyle(.secondary)
    }

    switch model.pairingState {
    case .idle:
      Text("Содержание передаётся после подтверждения на обоих устройствах.")
        .font(.callout).foregroundStyle(.secondary)
    case .invitation:
      Label("Приглашение создано. Ожидается iPad.", systemImage: "link")
        .accessibilityIdentifier("notebook.pairing.invitation-created")
    case .connecting:
      HStack { ProgressView().controlSize(.small); Text("Ожидается защищённое соединение…") }
    case .confirmation(let peer, let generation, let locallyConfirmed):
      VStack(alignment: .leading, spacing: 10) {
        Text(peer.displayName).font(.headline)
        Text("Устройство: \(peer.deviceID.uuidString.lowercased())")
          .font(.caption.monospaced()).textSelection(.enabled)
          .accessibilityIdentifier("notebook.pairing.peer-id")
        Text("Пространство: \(peer.workspaceID.uuidString.lowercased())")
          .font(.caption.monospaced()).textSelection(.enabled)
          .accessibilityIdentifier("notebook.pairing.workspace-id")
        Text("Сверьте устройство и пространство с iPad, прежде чем разрешить доступ.")
          .font(.callout)
        if locallyConfirmed {
          Text("Вы подтвердили. Ожидается подтверждение на iPad.")
            .accessibilityIdentifier("notebook.pairing.waiting-for-peer")
        } else {
          Button("Разрешить этому iPad доступ") { perform { try await model.confirmPairing(generation: generation) } }
            .accessibilityIdentifier("notebook.pairing.confirm")
        }
      }
    case .paired(let peer):
      Label("Подключено: \(peer.displayName)", systemImage: "checkmark.shield")
        .accessibilityIdentifier("notebook.pairing.paired")
    case .failed(let message):
      Text(message).foregroundStyle(.red)
        .accessibilityIdentifier("notebook.pairing.failure")
    }

    if case .idle = model.pairingState {} else {
      Button("Отменить сопряжение", role: .cancel) { perform { try await model.cancelPairing() } }
        .accessibilityIdentifier("notebook.pairing.cancel")
    }
    if !model.pairedPeers.isEmpty {
      Divider()
      Text("Доверенные устройства").font(.headline)
      ForEach(model.pairedPeers, id: \.deviceID) { peer in
        Button("Отозвать доступ: \(peer.displayName)", role: .destructive) {
          perform { try await model.revokePeer(peer.deviceID) }
        }
        .accessibilityIdentifier("notebook.pairing.revoke." + peer.deviceID.uuidString.lowercased())
      }
    }
  }

  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !performing else { return }; performing = true
    Task { @MainActor in
      defer { performing = false }
      do { try await operation(); error = nil }
      catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }
}
