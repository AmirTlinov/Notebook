import Foundation
import Testing
@testable import NotebookCore

@Suite("Program state admission prices and restores physical ink", .serialized)
struct NotebookProgramStateReadTests {
  @Test(arguments: [40, 600])
  func storedPortableInkRestoresExactOccurrenceAndChargesEveryReference(sampleCount: Int) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), id = UUID(), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let samples = (0..<sampleCount).map { i in
      SpatialInkSample(point: .init(x: sin(Double(i)), y: cos(Double(i * 7))),
        timeOffset: Double(i) / 120, width: 1 + Double(i % 7), opacity: 0.8,
        force: Double(i % 11) / 11, azimuth: 0.1, altitude: 0.8)
    }
    let first = try InkMeasurements(samples, revision: UUID()).encodedRelations().base64EncodedString()
    let second = try InkMeasurements(samples, revision: UUID()).encodedRelations().base64EncodedString()
    #expect(first.utf8.count > 1368)
    let fake: JSONValue = .object(["inkBody": .string(String(repeating: "f", count: 64)), "revision": .string(UUID().uuidString)])
    let value: JSONValue = .object(["state": .object([
      "z/quoted\"😀": .array([.string(first), fake]), "A": .string(second),
      "large": .string(String(repeating: "quoted \" } ] \\ 😀", count: 80_000))])])
    let file = stateFile(id), member = fieldKey([collaborationIdentity("body")])
    let address = file + "#/records/@" + member
    let fragment = NotebookStoredFragment(address: address, file: file, parent: file + "#", collection: "records",
      member: member, position: 0, value: value, collections: [])
    try store.commandTransaction { try store.writeFragment(fragment, database: store.currentSQL!) }
    let physical = try store.sqlRead { db in
      try JSONDecoder().decode(NotebookStoredFragment.self, from: db.rows("SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE address=?", [.text(address)]).first![0].blob!)
    }
    #expect(physical.inkBodies.count == 2)
    #expect(try physical.inkBodyHashes.count == 1, "Body equality must not erase occurrence revisions")
    let reopened = NotebookStore(root: root)
    let budget = try reopened.documentProgramStateReadBytes(documentID: id, blockID: "body")
    #expect(budget > (first.utf8.count + second.utf8.count) * 8)
    #expect(throws: NotebookStorageError.limitExceeded("program_state_admission")) {
      try reopened.readTransaction { _ in _ = try reopened.programStateFragments(address: address, admittedBytes: budget - 1) }
    }
    let restored = try reopened.readTransaction { _ in try reopened.programStateFragments(address: address, admittedBytes: budget) }
    #expect(restored == [fragment], "Declared NIM1 values expand exactly; lookalike user objects remain ordinary JSON")
    #expect(try reopened.documentProgramStateReadBytes(documentID: id, blockID: "body") == budget)
  }
}
