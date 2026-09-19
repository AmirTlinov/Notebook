import Foundation
import NotebookCore

/// Offline bootstrap for a fresh acceptance pair. Never opens or copies a live
/// workspace. Once launched, the applications own all changes and delivery.
@main struct NotebookAcceptance {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count == 6, args[1] == "prepare" else {
      throw failure("usage: notebook-acceptance prepare NEW_RUN_DIRECTORY SOURCE_SHA SIMULATOR_APP_CONTAINER MAC_BUNDLE_ID")
    }
    guard args[5].wholeMatch(of: /com\.amirtlinov\.notebook\.mac\.acceptance\.[0-9a-f]{12}/) != nil else {
      throw failure("Mac bundle must identify one isolated checkout")
    }
    let directory = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    guard let runID = UUID(uuidString: directory.lastPathComponent),
      directory.lastPathComponent == runID.uuidString.lowercased(), args[3].count == 40,
      args[3].allSatisfy({ $0.isHexDigit }), !FileManager.default.fileExists(atPath: directory.path) else {
      throw failure("run directory must be new and end in a lowercase UUID; source SHA is required")
    }
    let container = URL(fileURLWithPath: args[4], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let metadata = try Data(contentsOf: container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"))
    guard let object = try PropertyListSerialization.propertyList(from: metadata, format: nil) as? [String: Any],
      object["MCMMetadataIdentifier"] as? String == "com.amirtlinov.notebook.acceptance",
      container.pathComponents.contains("CoreSimulator") else {
      throw failure("destination is not the installed acceptance Simulator container")
    }
    let workspaceID = UUID(), seedActor = UUID(), macActor = UUID(), iPadActor = UUID()
    let initial = WorkspaceIndex.initial(actor: seedActor, pageSize: .init(width: 834, height: 1194))
    let content = CollaborationContent(workspace: initial.index,
      hierarchy: .initial(rootBoardID: initial.index.rootBoardID, itemIDs: initial.index.items.map(\.id), actor: seedActor),
      ink: .init(stamp: .init(counter: 0, actor: seedActor)), pages: [initial.page], documents: [], states: [])
    let checkpoint = NotebookCheckpoint(workspaceID: workspaceID, envelope: .init(content: content),
      presence: .init(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194),
        selectedItemID: initial.index.selectedItemID, notebookPageID: initial.page.id))
    try checkpoint.validate()
    let macRoot = directory.appendingPathComponent("mac", isDirectory: true)
    let iPadRoot = container.appendingPathComponent("Documents/acceptance/\(runID.uuidString.lowercased())/store", isDirectory: true)
    guard !FileManager.default.fileExists(atPath: iPadRoot.path) else { throw failure("Simulator run already exists") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let macReceipt = try NotebookStore(root: macRoot).installCheckpoint(checkpoint)
    let iPadReceipt = try NotebookStore(root: iPadRoot).installCheckpoint(checkpoint)
    guard macReceipt == iPadReceipt else { throw failure("checkpoint receipts differ") }
    let socket = "/tmp/notebook-acceptance-\(runID.uuidString.lowercased())/bridge.sock"
    func manifest(role: String, actor: UUID, bundle: String, root: URL) -> [String: Any] {
      var result: [String: Any] = ["version": 1, "runID": runID.uuidString, "workspaceID": workspaceID.uuidString,
        "actorID": actor.uuidString, "role": role, "bundleID": bundle, "sourceRevision": args[3], "root": root.path]
      if role == "mac" { result["socket"] = socket; result["codexDirectory"] = root.appendingPathComponent("Codex").path }
      return result
    }
    let macManifest = directory.appendingPathComponent("mac.json")
    let iPadManifest = iPadRoot.deletingLastPathComponent().appendingPathComponent("ipad.json")
    try write(manifest(role: "mac", actor: macActor, bundle: args[5], root: macRoot), to: macManifest)
    try write(manifest(role: "iPad", actor: iPadActor, bundle: "com.amirtlinov.notebook.acceptance", root: iPadRoot), to: iPadManifest)
    let result: [String: Any] = ["runID": runID.uuidString.lowercased(), "workspaceID": workspaceID.uuidString,
      "sourceRevision": args[3], "macManifest": macManifest.path, "iPadManifest": iPadManifest.path,
      "socket": socket, "checkpointSHA256": macReceipt.checkpointSHA256]
    try write(result, to: directory.appendingPathComponent("run.json"))
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  }

  static func write(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: [.withoutOverwriting])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  static func failure(_ message: String) -> NotebookStorageError { .invalidTransaction(message) }
}
