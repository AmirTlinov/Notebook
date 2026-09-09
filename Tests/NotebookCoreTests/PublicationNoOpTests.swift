import Foundation
import Testing
@testable import NotebookCore

@Test("Повтор тех же квитанции и камеры не создаёт повторного SQL commit")
func unchangedRuntimePublicationsDoNotRewriteFiles() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root)
  let receipt = DeviceActionReceipt(id: UUID(), deviceID: UUID(), revisions: [])
  try store.saveDeviceActionReceipt(receipt)
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
