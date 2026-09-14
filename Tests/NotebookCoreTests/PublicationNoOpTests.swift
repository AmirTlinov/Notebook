import Foundation
import Testing
@testable import NotebookCore

@Test("Повтор тех же квитанции и камеры не создаёт повторного SQL commit")
func unchangedRuntimePublicationsDoNotRewriteFiles() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root)
  let actor = UUID()
  let index = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194)).0
  _ = try store.loadOrCreateSpatialInk(actor: actor)
  let target = CollaborationTarget(kind: .board, id: index.rootBoardID)
  let action = try store.applyCollaborationAction(.init(summary: "A real receipt", expected: [
    .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
    .init(kind: .insertElement, target: target, id: "receipt", values: ["kind": .string("nativeText"),
      "source": .string("A receipt"), "worldOrigin": try .encode(WorldPoint.zero),
      "frame": try .encode(PageRect(x: 0, y: 0, width: 100, height: 50))])]), actor: actor)
  let receipt = DeviceActionReceipt(id: action.id, deviceID: actor, revisions: action.revisions,
    actionVersion: try action.deliveryVersion())
  #expect(try store.saveDeviceActionReceipt(receipt))
  let receiptRead = try store.currentReadCursor(), receiptChange = try store.currentChangeCursor()
  try store.saveDeviceActionReceipt(receipt)
  #expect(try store.currentReadCursor() == receiptRead)
  #expect(try store.currentChangeCursor() == receiptChange)
  let presence = SessionPresence(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194))
  try store.savePresence(presence)
  let presenceRead = try store.currentReadCursor()
  try store.savePresence(presence)
  #expect(try store.currentReadCursor() == presenceRead)
  #expect(try store.currentChangeCursor() == receiptChange)
}
