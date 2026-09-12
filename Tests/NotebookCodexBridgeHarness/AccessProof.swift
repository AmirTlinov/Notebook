import Foundation
import NotebookCore
import NotebookCodex

extension Proof {
  /// This task has no model turns and never uses the granted permissions. The
  /// proof changes only its native settings, then restores the project profile.
  static func exerciseAccess(_ bridge: CodexAppServer, installation: CodexDesktopInstallation, receipt: String) async throws {
    guard !FileManager.default.fileExists(atPath: receipt) else { throw CocoaError(.fileWriteFileExists) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-access-proof-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let task = try await bridge.create(directory: directory, title: "Notebook — проверка уровней доступа", workspaceID: UUID())
    print("Created disposable permission-settings task \(task.id)")
    do {
      try await bridge.attach(threadID: task.id)
      var observations: [CodexConversation] = []
      for mode in [CodexAccessMode.readOnly, .full, .workspace] {
        try await bridge.setAccess(threadID: task.id, mode: mode)
        guard let state = await bridge.snapshot(threadID: task.id), state.access?.mode == mode else { throw CodexBridgeError.invalidResponse }
        observations.append(state)
        print("Native settings event confirmed \(mode.rawValue)")
      }
      await bridge.close()
      let resumed = CodexAppServer(installation: installation)
      do {
        try await resumed.attach(threadID: task.id)
        guard let state = await resumed.snapshot(threadID: task.id), state.access?.mode == .workspace else { throw CodexBridgeError.invalidResponse }
        observations.append(state)
        await resumed.close()
      } catch { await resumed.close(); throw error }
      try write(observations, to: receipt)
      print("Native settings survived a new App Server connection; no model turn or permission use")
    } catch {
      // Revoke only this disposable task's test grant if a later assertion fails.
      try? await bridge.setAccess(threadID: task.id, mode: .workspace)
      await bridge.close()
      print("Failed; inspect disposable task \(task.id). No user task was changed.")
      throw error
    }
  }
}
