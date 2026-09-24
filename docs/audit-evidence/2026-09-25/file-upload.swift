import Foundation
import NotebookCore
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("notebook-audit-upload-" + UUID().uuidString)
defer { try? fm.removeItem(at: root) }
let store = NotebookStore(root: root), author = UUID()
_ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
let address = NotebookFileAddress(computer: UUID(), project: "audit", root: "/tmp", path: "fixture.txt")
for count in [262_144, 1_048_576, 2_097_152] {
 let edit = NotebookFileEdit(address: address, base: String(repeating: "a", count: count), text: String(repeating: "b", count: count))
 let payload = try JSONEncoder().encode(edit)
 let id = UUID(), digest = NotebookFileVersion.hash(payload), chunk = NotebookFileVersion.chunkBytes
 var offset = 0, parts = 0, priorBlobBytes = 0, boundBlobBytes = 0
 let start = ContinuousClock.now
 while offset < payload.count {
  let part = payload.subdata(in: offset..<min(payload.count, offset + chunk))
  priorBlobBytes += offset; boundBlobBytes += offset + part.count; parts += 1
  let accepted = try store.stageFileUpload(.init(id: id, digest: digest, total: payload.count, offset: offset, data: part), author: author)
  precondition(accepted == offset + part.count)
  offset = accepted
 }
 let restored = try store.stagedFileEdit(id, author: author)
 precondition(restored == edit)
 let elapsed = start.duration(to: .now).components
 let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds)/1e18
 let result: [String: Any] = ["sourceVersionBytes": count, "payloadBytes": payload.count, "chunks": parts, "algorithmPriorBlobBytes": priorBlobBytes, "algorithmBoundBlobBytes": boundBlobBytes, "stageSecondsOnThisMac": seconds]
 print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
}
