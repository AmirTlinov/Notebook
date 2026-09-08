import Foundation
import NotebookCore

/// A completed disk read is prepared away from input, then accepted only while
/// its captured in-memory version is still current. NotebookStore remains the
/// sole transaction and merge owner.
struct NotebookDiskRefresh: Sendable {
  let content: CollaborationContent
  let contentChanged: Bool
  let publication: CollaborationContent
  let actions: [CollaborationReceipt]
  let contexts: SharedContextSnapshot
  let delivery: [DeviceActionReceipt]
  let documentDrafts: [DocumentEditingSession]

  static func prepare(store: NotebookStore, local: CollaborationContent?, incoming: [CollaborationEnvelope], receivingDeviceID: UUID?) throws -> Self {
    let content: CollaborationContent
    if !incoming.isEmpty {
      let envelope = try incoming.reduce(CollaborationEnvelope()) { try $0.merging($1) }
      content = try store.receiveCollaboration(envelope, local: local)
        ?? store.mergeCollaborationContent(nil, local: local)
    } else {
      content = try store.mergeCollaborationContent(nil, local: local)
    }
    let actions = try store.collaborationActions()
    var delivery = try store.deviceActionReceipts()
    if let deviceID = receivingDeviceID {
      for action in actions where !delivery.contains(where: { $0.id == action.id && $0.revisions == action.revisions }) {
        let receipt = DeviceActionReceipt(id: action.id, deviceID: deviceID, revisions: action.revisions)
        try store.saveDeviceActionReceipt(receipt)
        delivery.removeAll { $0.id == receipt.id }; delivery.append(receipt)
      }
    }
    return try .init(content: content, contentChanged: content != local,
      publication: try content.publication(since: local), actions: actions,
      contexts: store.sharedContexts(), delivery: delivery, documentDrafts: store.documentEditingSessions())
  }
}
