import Foundation
import NotebookCore

struct Request: Decodable {
  let command: String
  let root: String
  let action: CollaborationAction?
  let actionID: UUID?
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
do {
  let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
  let store = NotebookStore(root: URL(fileURLWithPath: request.root, isDirectory: true))
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
  case "snapshot": data = try encoder.encode(store.collaborationSnapshot())
  default: throw CollaborationError("invalid_command", "Команда должна назвать действие моста.")
  }
  FileHandle.standardOutput.write(data)
} catch {
  let result = (error as? CollaborationError) ?? CollaborationError("operation_failed", error.localizedDescription)
  FileHandle.standardOutput.write(try encoder.encode(result))
  exit(1)
}
