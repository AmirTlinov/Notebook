import Darwin
import Foundation
import NotebookCore

struct ArchivePairRequest: Codable {
  let transitionID: UUID
  let legacyIPad: String
  let legacyMac: String
  let currentIPad: String
  let iPad: NotebookArchiveTarget
  let mac: NotebookArchiveTarget
}

struct ArchivePairReport: Codable {
  let transitionID: UUID
  let iPadManifest: NotebookArchiveActivationManifest
  let macManifest: NotebookArchiveActivationManifest
  let consolidation: ArchiveConsolidationReport
  let installedApplicationsChanged: Bool
}

enum ArchivePairPreparation {
  /// The entire pair is published as one external payload. The app-specific
  /// folders may be copied independently, but neither app admits its model
  /// until both actual activation receipts have been collected and checked.
  static func prepare(_ request: ArchivePairRequest, output: URL) throws -> ArchivePairReport {
    guard request.iPad.role == .iPad, request.mac.role == .mac,
      request.iPad.actorID != request.mac.actorID,
      request.iPad.bundleID == "com.amirtlinov.notebook.preview",
      request.mac.bundleID == "com.amirtlinov.notebook.mac",
      [request.legacyIPad, request.legacyMac, request.currentIPad].allSatisfy({ $0.hasPrefix("/") }) else {
      throw ArchiveTransferError.invalidSource("pair requires explicit independent backups and the existing iPad Lab/Mac identities")
    }
    let manager = FileManager.default
    guard !manager.fileExists(atPath: output.path) else { throw ArchiveTransferError.invalidSource("pair destination already exists") }
    let sources = [request.legacyIPad, request.legacyMac, request.currentIPad].map { URL(fileURLWithPath: $0) }
    let destination = output.standardizedFileURL.resolvingSymlinksInPath()
    guard sources.allSatisfy({ source in
      let source = source.standardizedFileURL.resolvingSymlinksInPath()
      return source != destination && !source.path.hasPrefix(destination.path + "/") && !destination.path.hasPrefix(source.path + "/")
    }) else { throw ArchiveTransferError.invalidSource("pair output must not overlap any source") }
    let proofs = try sources.map(inventory)
    let staging = output.deletingLastPathComponent().appendingPathComponent(".pair-" + UUID().uuidString)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: staging) }
    let combined = staging.appendingPathComponent("combined")
    let consolidation = try ArchiveConsolidation.prepare(legacyIPad: sources[0], legacyMac: sources[1],
      current: sources[2], destination: combined)
    let current = combined.appendingPathComponent("archive"), replica = staging.appendingPathComponent("mac-archive")
    let macPresence = try ArchiveSource.read(root: sources[1], workspaceID: consolidation.workspaceID).checkpoint.presence
    _ = try NotebookStore(root: current).prepareReplicaSnapshot(at: replica, presence: macPresence)
    let activation = NotebookArchiveActivation()
    let ipad = try activation.prepare(source: sources[2], candidate: current, output: staging.appendingPathComponent("ipad"),
      transitionID: request.transitionID, target: request.iPad)
    let mac = try activation.prepare(source: sources[1], candidate: replica, output: staging.appendingPathComponent("mac"),
      transitionID: request.transitionID, target: request.mac)
    guard ipad.content.workspaceID == mac.content.workspaceID,
      ipad.content.sharedRecordsSHA256 == mac.content.sharedRecordsSHA256,
      ipad.content.sharedRecordCount == mac.content.sharedRecordCount,
      try sources.map(inventory) == proofs else { throw ArchiveTransferError.invalidSource("pair source or shared content changed") }
    let report = ArchivePairReport(transitionID: request.transitionID, iPadManifest: ipad, macManifest: mac,
      consolidation: consolidation, installedApplicationsChanged: false)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: staging.appendingPathComponent("report.json"), options: .atomic)
    guard renamex_np(staging.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
      throw ArchiveTransferError.invalidSource("could not publish independent pair payload")
    }
    return report
  }
}
