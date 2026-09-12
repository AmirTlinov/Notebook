import Foundation

/// Evidence for a CURRENT iPad snapshot, separately from its initial activation.
/// The old pair keeps its admission and Keychain. Only a fresh Mac is admitted;
/// it must subsequently use ordinary explicit pairing, with its own actor ID.
public struct NotebookArchiveEnrollmentSource: Codable, Equatable, Sendable {
  public let sourcePair: [NotebookArchiveActivationReceipt]
  public let content: NotebookArchiveContentProof
  public let cursor: String

  public init(admission: NotebookArchiveAdmission, content: NotebookArchiveContentProof, cursor: UInt64) throws {
    guard admission.enrollment == nil else { throw NotebookStorageError.invalidTransaction("enrollment source must be the current iPad pair") }
    self.sourcePair = try NotebookArchiveAdmission(receipts: admission.receipts).receipts
    self.content = content; self.cursor = String(cursor)
    try validateSource()
  }
  private func validateSource() throws {
    let pair = try NotebookArchiveAdmission(receipts: sourcePair)
    try content.validate()
    guard pair.receipts == sourcePair, content.workspaceID == pair.receipts[0].content.workspaceID,
      let value = UInt64(cursor), value > 0, value <= VersionStamp.maximumCounter, String(value) == cursor else {
      throw NotebookStorageError.invalidTransaction("enrollment requires an exact current source frontier")
    }
  }
  func validate(receipts: [NotebookArchiveActivationReceipt]) throws {
    try validateSource()
    guard receipts.count == 2,
      let iPad = receipts.first(where: { $0.target.role == .iPad }), sourcePair.contains(iPad),
      let mac = receipts.first(where: { $0.target.role == .mac }),
      !sourcePair.contains(where: { $0.target.actorID == mac.target.actorID || $0.transitionID == mac.transitionID }),
      mac.content.workspaceID == content.workspaceID,
      mac.content.sharedRecordsSHA256 == content.sharedRecordsSHA256,
      mac.content.sharedRecordCount == content.sharedRecordCount else {
      throw NotebookStorageError.invalidTransaction("new Mac must retain the current shared content with an independent identity")
    }
  }
  public func admission(receipt: NotebookArchiveActivationReceipt, manifest: NotebookArchiveActivationManifest) throws -> NotebookArchiveAdmission {
    guard receipt.target.role == .mac, receipt.target == manifest.target, receipt.transitionID == manifest.transitionID,
      receipt.content == manifest.content, receipt.manifestSHA256 == (try collaborationHash(manifest)),
      let source = sourcePair.first(where: { $0.target.role == .iPad }) else {
      throw NotebookStorageError.invalidTransaction("enrollment receipt does not match the prepared Mac")
    }
    return try .init(receipts: [source, receipt], enrollment: self)
  }
  public func publishAdmission(receipt: NotebookArchiveActivationReceipt, manifest: NotebookArchiveActivationManifest, at file: URL) throws {
    try NotebookArchiveFiles.publish(admission(receipt: receipt, manifest: manifest), at: file, withoutOverwriting: true)
  }
}
