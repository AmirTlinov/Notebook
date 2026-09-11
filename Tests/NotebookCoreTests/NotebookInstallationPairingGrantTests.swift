import Foundation
import Testing
@testable import NotebookCore

@Suite("USB installation pairing names only the activated pair")
struct NotebookInstallationPairingGrantTests {
  private func admission() throws -> NotebookArchiveAdmission {
    let workspace = UUID(), transition = UUID()
    let content = NotebookArchiveContentProof(workspaceID: workspace,
      sharedRecordsSHA256: String(repeating: "a", count: 64), sharedRecordCount: 1, totalRecordCount: 1)
    return try .init(receipts: [
      .init(transitionID: transition, target: .init(role: .iPad, bundleID: "fixture.ipad", actorID: UUID()),
        manifestSHA256: String(repeating: "b", count: 64), content: content),
      .init(transitionID: transition, target: .init(role: .mac, bundleID: "fixture.mac", actorID: UUID()),
        manifestSHA256: String(repeating: "c", count: 64), content: content)])
  }

  @Test func reciprocalIdentitiesUseOneFresh256BitCredential() throws {
    let admitted = try admission(), grant = try NotebookInstallationPairingGrant(admission: admitted)
    #expect(grant.secret.count == 32)
    #expect(try grant.peer(for: admitted.receipts[0], admitted: admitted) == admitted.receipts[1])
    #expect(try grant.peer(for: admitted.receipts[1], admitted: admitted) == admitted.receipts[0])
    let next = try NotebookInstallationPairingGrant(admission: admitted)
    #expect(next.pairingID != grant.pairingID && next.secret != grant.secret)
    let reopened = try JSONDecoder().decode(NotebookInstallationPairingGrant.self, from: JSONEncoder().encode(grant))
    #expect(try reopened == grant && reopened.fingerprint == grant.fingerprint)
  }

  @Test func foreignPairAndForeignReceiptCannotAuthorize() throws {
    let a = try admission(), b = try admission(), grant = try NotebookInstallationPairingGrant(admission: a)
    #expect(throws: NotebookStorageError.self) { try grant.peer(for: a.receipts[0], admitted: b) }
    #expect(throws: NotebookStorageError.self) { try grant.peer(for: b.receipts[0], admitted: a) }
  }

  @Test(arguments: [0, 16, 31, 33]) func rejectsIncorrectSecretLength(_ count: Int) throws {
    let admitted = try admission(), grant = try NotebookInstallationPairingGrant(admission: admitted)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as? [String: Any])
    object["secret"] = Data(repeating: 1, count: count).base64EncodedString()
    let corrupted = try JSONDecoder().decode(NotebookInstallationPairingGrant.self,
      from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: NotebookStorageError.self) { try corrupted.peer(for: admitted.receipts[0], admitted: admitted) }
  }

  @Test func rejectsUnknownFormat() throws {
    let admitted = try admission(), grant = try NotebookInstallationPairingGrant(admission: admitted)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as? [String: Any])
    object["format"] = 2
    let corrupted = try JSONDecoder().decode(NotebookInstallationPairingGrant.self,
      from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: NotebookStorageError.self) { try corrupted.peer(for: admitted.receipts[0], admitted: admitted) }
  }
  @Test func publishesPrivateFileOnceWithoutReplacingAnExistingGrant() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let grant = try NotebookInstallationPairingGrant(admission: admission())
    let file = root.appendingPathComponent(NotebookInstallationPairingGrant.fileName)
    try grant.publish(at: file)
    let before = try Data(contentsOf: file)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(throws: (any Error).self) { try grant.publish(at: file) }
    #expect(try Data(contentsOf: file) == before)
  }

}
