import NotebookCore

import Foundation
import AppKit
import NotebookCodex

@main struct Proof {
  static func write<T: Encodable>(_ value: T, to path: String? = nil) throws {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    if let path { try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting) }
    else { print(String(decoding: data, as: UTF8.self)) }
  }

  static func wait(_ bridge: CodexAppServer, threadID: String,
    until predicate: @Sendable (CodexConversation) -> Bool) async throws -> CodexConversation {
    let deadline = ContinuousClock.now.advanced(by: .seconds(90))
    while .now < deadline {
      if let state = await bridge.snapshot(threadID: threadID), predicate(state) { return state }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw CodexBridgeError.timeout
  }

  static func main() async {
    do { try await run() }
    catch { print("Proof failed: \(error)"); exit(1) }
  }

  static func run() async throws {
    let foreground = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    let installation = try await CodexDesktopInstallation.discover()
    let metadata = CodexAppServer(installation: installation)
    let args = CommandLine.arguments
    if args.count == 3, args[1] == "composer" { try await exerciseComposer(metadata, installation: installation, receipt: args[2]); return }
    if args.count == 3, args[1] == "access" { try await exerciseAccess(metadata, installation: installation, receipt: args[2]); return }
    if args.count == 3, args[1] == "run" { try await exerciseRun(metadata, receipt: args[2]); return }
    if args.count == 4, args[1] == "project-update" {
      try write(await metadata.updateProject(.init(id: args[2], name: args[3], roots: nil))); return
    }
    if args.count >= 2, args[1] == "projects" {
      let projects = try await metadata.projects()
      if args.count == 3, let project = projects.projects.first(where: { $0.id == args[2] }) {
        try write(await metadata.tasks(project: project))
      } else { try write(projects) }
      return
    }
    if args.count == 3, args[1] == "observe" {
      let bridge = metadata
      do {
        try await bridge.attach(threadID: args[2])
        let state = try await wait(bridge, threadID: args[2]) { $0.ready }
        try write(state); await bridge.close(); return
      } catch { await bridge.close(); throw error }
    }
    if args.count == 3, args[1] == "history" {
      try write(await metadata.history(threadID: args[2])); return
    }
    guard args.count == 3, args[1] == "exercise" else {
      try write(await metadata.tasks()); return
    }
    guard !FileManager.default.fileExists(atPath: args[2]) else { throw CocoaError(.fileWriteFileExists) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-codex-proof-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    print("Reading native catalogue")
    let catalogue = try await metadata.tasks()
    print("Creating native metadata task")
    let task = try await metadata.create(directory: directory, title: "Notebook — проверка нативного моста", workspaceID: UUID())
    print("Created disposable task \(task.id)")
    let bridge = metadata
    do {
      try await bridge.attach(threadID: task.id)
      _ = try await wait(bridge, threadID: task.id) { $0.ready && !$0.busy }
      let clientID = UUID()
      let firstTurn = try await bridge.send(threadID: task.id, clientMessageID: clientID,
        text: "Ответь только: 2 + 2 = 4. Это проверка прямого моста Notebook. Не вызывай инструменты.",
        context: "Изолированный тестовый архив Notebook. Настоящие рисунки и файлы человека не используются.")
      let answered = try await wait(bridge, threadID: task.id) { $0.turnStatuses[firstTurn] == "completed" }
      guard answered.messages.contains(where: { $0.turnID == firstTurn && $0.role == .assistant && $0.text.contains("2 + 2 = 4") }),
        answered.acceptedMessages[clientID.uuidString.lowercased()] == firstTurn else { throw CodexBridgeError.invalidResponse }
      print("Same-task reply and stable message ID passed")
      let foreign = CodexAppServer(installation: installation)
      do {
        try await foreign.attach(threadID: task.id)
        await foreign.close(); throw CodexBridgeError.invalidResponse
      } catch CodexBridgeError.externalOwnerUnavailable { await foreign.close() }
      guard await bridge.snapshot(threadID: task.id)?.ready == true else { throw CodexBridgeError.invalidResponse }
      print("Second executor rejected without disturbing the first")
      // Repeating a known accepted ID returns its turn without making a second turn.
      let duplicate = try await bridge.send(threadID: task.id, clientMessageID: clientID, text: "Ответь только: 2 + 2 = 4. Это проверка прямого моста Notebook. Не вызывай инструменты.")
      guard duplicate == firstTurn else { throw CodexBridgeError.invalidResponse }
      await bridge.close()
      let history = try await metadata.history(threadID: task.id)
      guard history.messages.filter({ $0.clientID == clientID.uuidString.lowercased() }).count == 1 else { throw CodexBridgeError.invalidResponse }
      try await bridge.attach(threadID: task.id)
      _ = try await wait(bridge, threadID: task.id) { $0.ready && !$0.busy }
      print("Disconnect and canonical paged history passed")
      let permissionTurn = try await bridge.send(threadID: task.id, clientMessageID: UUID(), text: """
        Это проверка запроса разрешения. Вызови request_permissions для права записи только в /tmp/notebook-codex-permission-proof. Ничего не записывай. Дождись ответа; тест отклонит запрос. Если инструмент недоступен, сообщи, не заменяй его другим действием.
        """)
      let asking = try await wait(bridge, threadID: task.id) { !$0.requests.isEmpty }
      guard let request = asking.requests.first, request.turnID == permissionTurn,
        request.method == "item/permissions/requestApproval" else { throw CodexBridgeError.invalidResponse }
      // The proof deliberately declines. The production adapter NEVER chooses a decision.
      try await bridge.respond(threadID: task.id, request: request, decision: .decline)
      _ = try await wait(bridge, threadID: task.id) { $0.turnStatuses[permissionTurn] == "completed" && $0.requests.isEmpty }
      print("Native permission request and explicit denial passed")
      let stopTurn = try await bridge.send(threadID: task.id, clientMessageID: UUID(), text: "Запусти команду sleep 60. Это изолированная проверка остановки текущего хода. Больше ничего не делай.")
      _ = try await wait(bridge, threadID: task.id) { $0.activeTurnID == stopTurn }
      let steeringTurn = try await bridge.steer(threadID: task.id, turnID: stopTurn, clientMessageID: UUID(),
        text: "Уточнение проверки: не изменяй файлы и не запускай ничего кроме запрошенного sleep.")
      guard steeringTurn == stopTurn else { throw CodexBridgeError.invalidResponse }
      print("Explicit clarification kept the same active turn")
      try await bridge.interrupt(threadID: task.id, turnID: stopTurn)
      _ = try await wait(bridge, threadID: task.id) { $0.turnStatuses[stopTurn] == "interrupted" }
      print("Expected-turn interruption passed")
      await bridge.close()
      let foregroundAfter = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
      let receipt = Receipt(checkedAt: Date(), appVersion: Bundle(url: installation.application)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        appBuild: Bundle(url: installation.application)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", threadID: task.id, clientMessageID: clientID.uuidString.lowercased(),
        answeredTurnID: firstTurn, permissionTurnID: permissionTurn, stoppedTurnID: stopTurn,
        catalogueCount: catalogue.tasks.count, historyMessageCount: history.messages.count,
        nativeBridgePassed: true, foregroundUnchanged: foreground == foregroundAfter, steeringPassed: true, secondWriterRejected: true, featureReady: false, disposableTaskArchived: false,
        notProven: ["nativeProjectlessMembership", "sidecarOutboxRecovery", "pairedIPadChat", "bundledNotebookTools", "physicalIPad"])
      try write(receipt, to: args[2]); try write(receipt)
    } catch {
      await bridge.close()
      print("FAILED; inspect disposable task \(task.id). It was not silently recreated or archived.")
      throw error
    }
  }

  struct Receipt: Codable {
    let checkedAt: Date
    let appVersion, appBuild, threadID, clientMessageID, answeredTurnID, permissionTurnID, stoppedTurnID: String
    let catalogueCount, historyMessageCount: Int
    let nativeBridgePassed, foregroundUnchanged, steeringPassed, secondWriterRejected, featureReady, disposableTaskArchived: Bool
    let notProven: [String]
  }
}
