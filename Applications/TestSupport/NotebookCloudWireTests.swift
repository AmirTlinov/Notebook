import CloudKit
import CryptoKit
import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookCloudWireTests: XCTestCase {
  private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  func testExistingAssetMetadataDoesNotRequireAnotherDownloadToDeduplicate() throws {
    let data = Data("Immutable".utf8), hash = hash(data)
    let value = try NotebookCloudRecord.chunk(hash: hash, offset: 0, totalBytes: Int64(data.count))
    let record = CKRecord(recordType: "NotebookBlob", recordID: .init(recordName: value.id))
    record["format"] = 1 as NSNumber; record["hash"] = hash as NSString
    record["offset"] = 0 as NSNumber; record["total"] = data.count as NSNumber; record["digest"] = hash as NSString
    XCTAssertEqual(try NotebookCloudSync.descriptor(record), value)
    // Metadata alone can confirm an existing immutable server record, but it
    // is never sufficient to publish a newly fetched content dependency.
    XCTAssertThrowsError(try NotebookCloudSync.decode(record))
  }

  func testDownloadedAssetMustHaveExactlyTheDeclaredContent() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-asset-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let data = Data("Known content".utf8), hash = hash(data)
    try data.write(to: file)
    let value = try NotebookCloudRecord.chunk(hash: hash, offset: 0, totalBytes: Int64(data.count))
    let record = CKRecord(recordType: "NotebookBlob", recordID: .init(recordName: value.id))
    record["format"] = 1 as NSNumber; record["hash"] = hash as NSString
    record["offset"] = 0 as NSNumber; record["total"] = data.count as NSNumber; record["digest"] = hash as NSString
    record["asset"] = CKAsset(fileURL: file)
    XCTAssertEqual(try NotebookCloudSync.decode(record).1, data)
    try Data("Wrong content".utf8).write(to: file)
    XCTAssertThrowsError(try NotebookCloudSync.decode(record))
  }

  func testEnvelopeRecordNameCommitsToSourceGenerationAndSnapshotBoundary() throws {
    let device = UUID(), generation = UUID()
    let change = NotebookDurableChange(sequence: 50, transactionID: UUID(), manifestHash: String(repeating: "a", count: 64), byteCount: 500)
    let delivery = NotebookReplicationDelivery(source: .init(deviceID: device, generation: generation), change: change, isSnapshot: true)
    let value = try NotebookCloudRecord(delivery: delivery)
    let record = CKRecord(recordType: "NotebookDelivery", recordID: .init(recordName: value.id))
    record["format"] = 1 as NSNumber; record["body"] = try JSONEncoder().encode(delivery) as NSData
    XCTAssertEqual(try NotebookCloudSync.decode(record).0, value)
    record["body"] = try JSONEncoder().encode(NotebookReplicationDelivery(source: delivery.source, change: change)) as NSData
    XCTAssertThrowsError(try NotebookCloudSync.decode(record))
  }

  func testDisabledCloudNeverNeedsContainerEntitlementsOrAnAccount() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-off-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try store.prepareCloudStorage()
    let source = try store.replicationSource(deviceID: actor)
    let cloud = NotebookCloudSync(store: store, writer: NotebookPersistenceQueue(store: store), source: source, workspaceID: header.workspaceID,
      apply: { _, _ in throw NotebookTransportError.disconnected }, report: { _ in })
    await cloud.resume()
    XCTAssertFalse(try store.cloudConfiguration().enabled)
    XCTAssertEqual(try store.workspaceHeader().workspaceID, header.workspaceID)
    await cloud.stop()
  }
}
