import Foundation
import NotebookCore

struct Request: Decodable {
  let query: String?
  let limit: Int?
  let command: String
  let root: String
  let action: CollaborationAction?
  let actionID: UUID?
  let target: CollaborationTarget?
  let elementID: String?
  let reference: CollaborationReference?
  let expectedRevision: String?
  let region: PageRect?
  let worldOrigin: WorldPoint?
  let pageIndex: Int?
  let placement: CollaborationPlacementRequest?
  let contextID: UUID?
  let replyTo: UUID?
  let references: [CollaborationReference]?
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
do {
  let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
  let store = NotebookStore(root: URL(fileURLWithPath: request.root, isDirectory: true))
  try store.migrateCollaborationStorage()
  let data: Data
  switch request.command {
  case "apply":
    guard let action = request.action else { throw CollaborationError("invalid_action", "Нужен законченный ход.") }
    data = try encoder.encode(store.applyCollaborationAction(action, actor: store.collaborationActorID()))
  case "undo":
    guard let id = request.actionID else { throw CollaborationError("invalid_action", "Нужен ID хода.") }
    data = try encoder.encode(store.undoCollaborationAction(id, actor: store.collaborationActorID()))
  case "action":
    guard let id = request.actionID else { throw CollaborationError("invalid_action", "Нужен ID хода.") }
    data = try encoder.encode(store.collaborationAction(id))
  case "actions": data = try encoder.encode(store.collaborationActions())
  case "continuations":
    guard let id = request.actionID else { throw CollaborationError("invalid_action", "Нужен ID хода.") }
    data = try encoder.encode(store.collaborationContinuations(id))
  case "search": data = try encoder.encode(store.search(request.query ?? "", limit: request.limit ?? 20))
  case "snapshot": data = try encoder.encode(store.collaborationSnapshot())
  case "contexts": data = try encoder.encode(store.sharedContexts())
  case "point":
    data = try encoder.encode(store.appendContext(references: request.references ?? [], author: .agent,
      actor: store.collaborationActorID(), contextID: request.contextID, replyTo: request.replyTo))
  case "delivery": data = try encoder.encode(store.deviceActionReceipts())
  case "referenceStatus":
    guard let reference = request.reference else { throw CollaborationError("invalid_reference", "Нужна рассмотренная ссылка.") }
    data = try encoder.encode(store.referenceStatus(reference))
  case "reference":
    guard let target = request.target else { throw CollaborationError("invalid_reference", "Нужен владелец указания.") }
    data = try encoder.encode(["revision": store.referenceRevision(target: target, elementID: request.elementID)])
  case "placement":
    guard let placement = request.placement else { throw CollaborationError("invalid_placement", "Нужен пакет размещения.") }
    data = try encoder.encode(store.suggestCollaborationPlacement(placement))
  case "render":
    guard let target = request.target, let revision = request.expectedRevision else { throw CollaborationError("invalid_reference", "Нужны владелец и прочитанная версия.") }
    data = try encoder.encode(store.requestTargetRender(target: target, expectedRevision: revision,
      region: request.region, worldOrigin: request.worldOrigin, pageIndex: request.pageIndex ?? 0))
  default: throw CollaborationError("invalid_command", "Команда должна назвать действие моста.")
  }
  FileHandle.standardOutput.write(data)
} catch {
  let result = (error as? CollaborationError) ?? CollaborationError("operation_failed", error.localizedDescription)
  FileHandle.standardOutput.write(try encoder.encode(result))
  exit(1)
}
