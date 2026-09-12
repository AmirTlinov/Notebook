import Foundation
import NotebookCore
import NotebookCodex

extension Proof {
  static func exerciseComposer(_ bridge: CodexAppServer, installation: CodexDesktopInstallation, receipt: String) async throws {
    guard !FileManager.default.fileExists(atPath: receipt) else { throw CocoaError(.fileWriteFileExists) }
    let options = try await bridge.models()
    guard let option = options.first(where: { $0.efforts.contains("low") }), options.count > 1 else { throw CodexBridgeError.invalidResponse }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-composer-proof-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let file = directory.appendingPathComponent("example.txt")
    try Data("Notebook composer".utf8).write(to: file)
    let task = try await bridge.create(directory: directory, title: "Notebook — проверка панели ввода", workspaceID: UUID())
    print("Disposable composer task \(task.id)")
    do {
      try await bridge.attach(threadID: task.id)
      print("Attached")
      var resources: [String: Int] = [:]
      for kind in CodexResourceKind.allCases {
        print("Reading \(kind.rawValue)")
        let page = try await bridge.resources(threadID: task.id, kind: kind, cursor: nil)
        resources[kind.rawValue] = page.resources.count
      }
      print("Resources read")
      let selection = CodexModelSelection(model: option.id, effort: "low")
      try await bridge.setModel(threadID: task.id, selection: selection)
      guard let settings = await bridge.snapshot(threadID: task.id), settings.model == selection else { throw CodexBridgeError.invalidResponse }
      print("Settings confirmed")
      let id = UUID()
      let turn = try await bridge.send(threadID: task.id, clientMessageID: id,
        text: "Ответь только: Notebook composer. Не вызывай инструменты. Это изолированная проверка панели ввода.",
        attachments: [.init(kind: .file, name: file.lastPathComponent, path: file.path)])
      print("Turn admitted \(turn)")
      let answered = try await wait(bridge, threadID: task.id) { $0.turnStatuses[turn] == "completed" && $0.contextUsage != nil }
      guard answered.acceptedMessages[id.uuidString.lowercased()] == turn else { throw CodexBridgeError.invalidResponse }
      await bridge.close()
      let resumed = CodexAppServer(installation: installation)
      do {
        try await resumed.attach(threadID: task.id)
        let cold = try await wait(resumed, threadID: task.id) { $0.ready }
        guard cold.model == selection else { throw CodexBridgeError.invalidResponse }
        struct Receipt: Encodable { let models: [CodexModelOption]; let resources: [String: Int]; let answered: CodexConversation; let resumed: CodexConversation }
        try write(Receipt(models: options, resources: resources, answered: answered, resumed: cold), to: receipt)
        await resumed.close()
        print("Model/effort, native resources, stable message acceptance and usage verified; resumed usage: \(cold.contextUsage?.used.description ?? "unavailable")")
      } catch { await resumed.close(); throw error }
    } catch { await bridge.close(); throw error }
  }
}
