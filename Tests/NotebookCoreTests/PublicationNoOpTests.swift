import Foundation
import Testing
@testable import NotebookCore

@Test("Повтор тех же квитанции и камеры не создаёт файлового эха")
func unchangedRuntimePublicationsDoNotRewriteFiles() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root)
  let receipt = DeviceActionReceipt(id: UUID(), deviceID: UUID(), revisions: [])
  try store.saveDeviceActionReceipt(receipt)
  let url = store.deviceReceiptsURL.appendingPathComponent(receipt.id.uuidString.lowercased() + ".json")
  let date = Date(timeIntervalSince1970: 123_456)
  try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  try store.saveDeviceActionReceipt(receipt)
  #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == date)
  let presence = SessionPresence(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194))
  try store.savePresence(presence)
  try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: store.presenceURL.path)
  try store.savePresence(presence)
  #expect(try FileManager.default.attributesOfItem(atPath: store.presenceURL.path)[.modificationDate] as? Date == date)
}
