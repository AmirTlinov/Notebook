#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import NotebookCore

struct NotebookRelaySettingsView: View {
  let model: NotebookAppModel
  let peer: NotebookTransportIdentity
  @State private var importing = false
  @State private var working = false
  @State private var enabled = false
  @State private var failure: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Интернет-доступ · \(peer.displayName)").font(.headline)
      Text("Mac остаётся владельцем проекта и задач. Relay передаёт только зашифрованный поток. Устройство должно сначала подключиться напрямую, чтобы получить маршрут.")
      Label(enabled ? "Интернет-доступ включён" : "Интернет-доступ выключен", systemImage: enabled ? "network" : "network.slash")
        .accessibilityIdentifier("notebook.relay.status")
      if enabled {
        Button("Отключить интернет-доступ", role: .destructive) { change(nil) }
      } else {
        Button("Подключить relay…") { importing = true }.accessibilityIdentifier("notebook.relay.import")
        Text("Выберите выданный администратором файл маршрута. Это не ключ Codex и не токен ChatGPT. Файл содержит секрет доступа к relay; после импорта храните его защищённо.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      Text("Отключение relay не останавливает задачи и не отзывает локальное сопряжение. Полный отзыв устройства находится в его меню.")
        .font(.footnote).foregroundStyle(.secondary)
      if let failure { Text(failure).foregroundStyle(.red) }
      if working { ProgressView() }
    }
    .padding(24).frame(width: 450).disabled(working)
    .onAppear { enabled = model.remoteAccessEnabled(peer.deviceID) }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
      do {
        let url = try result.get(), access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard data.count <= 4096 else { throw NotebookTransportError.frameTooLarge }
        let route = try JSONDecoder().decode(NotebookRelayRoute.self, from: data)
        guard route.isValid else { throw NotebookTransportError.authenticationRequired }
        change(route)
      } catch { failure = "Не удалось прочитать защищённый файл маршрута." }
    }
  }
  private func change(_ route: NotebookRelayRoute?) {
    working = true; failure = nil
    Task {
      defer { working = false }
      do { try await model.configureRemoteAccess(peer.deviceID, route: route); enabled = route != nil }
      catch { failure = "Relay недоступен или файл маршрута отклонён. Прежнее сопряжение не изменено." }
    }
  }
}
#endif
