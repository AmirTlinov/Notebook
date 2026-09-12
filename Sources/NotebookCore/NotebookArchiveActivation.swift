import Darwin
import Foundation

public struct NotebookArchiveTarget: Codable, Equatable, Sendable {
  public enum Role: String, Codable, Sendable { case iPad, mac }
  public let role: Role
  public let bundleID: String
  public let actorID: UUID
  public init(role: Role, bundleID: String, actorID: UUID) {
    self.role = role; self.bundleID = bundleID; self.actorID = actorID
  }
}

public struct NotebookArchiveActivationManifest: Codable, Equatable, Sendable {
  public let format: Int
  public let transitionID: UUID
  public let target: NotebookArchiveTarget
  public let source: NotebookArchiveFingerprint
  public let candidate: NotebookArchiveFingerprint
  public let content: NotebookArchiveContentProof
}

public struct NotebookArchiveActivationReceipt: Codable, Equatable, Sendable {
  public let transitionID: UUID
  public let target: NotebookArchiveTarget
  public let manifestSHA256: String
  public let content: NotebookArchiveContentProof
}

public struct NotebookArchiveAdmission: Codable, Equatable, Sendable {
  public let receipts: [NotebookArchiveActivationReceipt]
  public let enrollment: NotebookArchiveEnrollmentSource?
  public init(receipts: [NotebookArchiveActivationReceipt], enrollment: NotebookArchiveEnrollmentSource? = nil) throws {
    for receipt in receipts {
      try receipt.content.validate()
      guard NotebookArchiveContentProof.isSHA256(receipt.manifestSHA256), !receipt.target.bundleID.isEmpty else {
        throw NotebookStorageError.invalidTransaction("invalid activation receipt")
      }
    }
    guard receipts.count == 2, Set(receipts.map { $0.target.role }).count == 2,
      receipts[0].target.actorID != receipts[1].target.actorID,
      receipts[0].content.workspaceID == receipts[1].content.workspaceID else {
      throw NotebookStorageError.invalidTransaction("admission requires distinct devices in one workspace")
    }
    if let enrollment { try enrollment.validate(receipts: receipts) }
    else {
      guard receipts[0].transitionID == receipts[1].transitionID,
        receipts[0].content.sharedRecordsSHA256 == receipts[1].content.sharedRecordsSHA256,
        receipts[0].content.sharedRecordCount == receipts[1].content.sharedRecordCount else {
        throw NotebookStorageError.invalidTransaction("both devices must activate the same shared archive")
      }
    }
    self.receipts = receipts.sorted { $0.target.role.rawValue < $1.target.role.rawValue }
    self.enrollment = enrollment
  }

  /// An enrollment admits only its new Mac. It cannot replace the current
  /// iPad's pair admission or cause either existing device to re-activate.
  func admits(_ receipt: NotebookArchiveActivationReceipt) -> Bool {
    receipts.contains(receipt) && (enrollment == nil || receipt.target.role == .mac)
  }

  /// An installer supplies the two actual device receipts, never just a flag.
  public func publish(at control: URL) throws {
    _ = try Self(receipts: receipts, enrollment: enrollment)
    let local = try NotebookArchiveFiles.read(NotebookArchiveActivationReceipt.self,
      at: control.appendingPathComponent("activation.json"))
    guard admits(local) else { throw NotebookStorageError.invalidTransaction("admission does not include this activation") }
    try NotebookArchiveFiles.publish(self, at: control.appendingPathComponent("admission.json"))
  }
}

public enum NotebookArchiveLaunch: Equatable, Sendable {
  case unchanged
  case waitingForPair(NotebookArchiveActivationReceipt)
  case admitted(NotebookArchiveActivationReceipt)
}

enum NotebookArchiveActivationFault: CaseIterable {
  case afterCandidateCopy, beforeManifestPublication, afterLocalDurability, beforeSwap, afterSwap, beforeReceipt, afterReceipt
}

private struct NotebookArchiveActivationMarker: Codable, Equatable {
  let transitionID: UUID
  let target: NotebookArchiveTarget
  let content: NotebookArchiveContentProof
}

/// One local atomic directory exchange, followed by a durable admission of the
/// pair. This bootstrap runs before NotebookAppModel opens its sole SQL owner.
public struct NotebookArchiveActivation: Sendable {
  private let fault: (@Sendable (NotebookArchiveActivationFault) throws -> Void)?
  private let availableBytes: (@Sendable (URL) throws -> UInt64)?
  private let localSyncFile: @Sendable (URL) throws -> Void
  public init() { fault = nil; availableBytes = nil; localSyncFile = { try NotebookArchiveFiles.syncFile($0) } }
  init(fault: (@Sendable (NotebookArchiveActivationFault) throws -> Void)? = nil,
    availableBytes: (@Sendable (URL) throws -> UInt64)? = nil,
    localSyncFile: (@Sendable (URL) throws -> Void)? = nil) {
    self.fault = fault; self.availableBytes = availableBytes
    self.localSyncFile = localSyncFile ?? { try NotebookArchiveFiles.syncFile($0) }
  }
  public static func controlURL(for root: URL) -> URL {
    root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".activation", isDirectory: true)
  }
  private static let markerName = ".notebook-activation.json"

  /// Build an independent payload; never changes source or candidate. The
  /// source can be opaque old files, but the candidate must pass new Core.
  public func prepare(source: URL, candidate: URL, output: URL, transitionID: UUID,
    target: NotebookArchiveTarget) throws -> NotebookArchiveActivationManifest {
    let manager = FileManager.default
    let roots = [source, candidate, output].map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    guard !manager.fileExists(atPath: output.path), !target.bundleID.isEmpty,
      roots.enumerated().allSatisfy({ index, root in
        roots.enumerated().allSatisfy { other, value in index == other || (root != value && !root.path.hasPrefix(value.path + "/")) }
      }) else { throw NotebookStorageError.invalidTransaction("activation requires disjoint sources and a new destination") }
    let sourceProof = try NotebookArchiveFingerprint.read(source), candidateProof = try NotebookArchiveFingerprint.read(candidate)
    let staging = output.deletingLastPathComponent().appendingPathComponent(".activation-" + UUID().uuidString)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: staging) }
    let prepared = staging.appendingPathComponent("candidate", isDirectory: true)
    try manager.copyItem(at: candidate, to: prepared)
    guard try NotebookArchiveFingerprint.read(prepared) == candidateProof else { throw NotebookStorageError.transactionConflict }
    try fault?(.afterCandidateCopy)
    let content = try NotebookStore(root: prepared).validateArchiveSnapshot()
    let marker = NotebookArchiveActivationMarker(transitionID: transitionID, target: target, content: content)
    try NotebookArchiveFiles.publish(marker, at: prepared.appendingPathComponent(Self.markerName))
    let fingerprint = try NotebookArchiveFingerprint.read(prepared)
    let manifest = NotebookArchiveActivationManifest(format: 1, transitionID: transitionID, target: target,
      source: sourceProof, candidate: fingerprint, content: content)
    try NotebookArchiveFiles.syncTree(prepared, proof: fingerprint)
    try fault?(.beforeManifestPublication)
    guard try NotebookArchiveFingerprint.read(source) == sourceProof,
      try NotebookArchiveFingerprint.read(candidate) == candidateProof else { throw NotebookStorageError.transactionConflict }
    try NotebookArchiveFiles.publish(manifest, at: staging.appendingPathComponent("transition.json"))
    guard renamex_np(staging.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
      throw NotebookArchiveFiles.failure("publish activation payload without replacement")
    }
    try NotebookArchiveFiles.syncDirectory(output.deletingLastPathComponent())
    return manifest
  }

  public func launch(root: URL, target: NotebookArchiveTarget) throws -> NotebookArchiveLaunch {
    let manager = FileManager.default, control = Self.controlURL(for: root)
    guard manager.fileExists(atPath: control.path) else { return .unchanged }
    try NotebookArchiveFiles.requireDirectory(control)
    let descriptor = open(control.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw NotebookArchiveFiles.failure("open activation lock") }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw NotebookStorageError.transactionConflict }
    defer { flock(descriptor, LOCK_UN) }
    let receiptURL = control.appendingPathComponent("activation.json")
    if manager.fileExists(atPath: receiptURL.path) {
      let receipt = try NotebookArchiveFiles.read(NotebookArchiveActivationReceipt.self, at: receiptURL)
      guard receipt.target == target else { throw NotebookStorageError.invalidTransaction("activation target mismatch") }
      // The durable receipt is the sole completed transition owner. Ordinary
      // cold launch does not decode inventories proportional to the archive.
      return try admissionStatus(root: root, receipt: receipt)
    }
    let manifest = try NotebookArchiveFiles.read(NotebookArchiveActivationManifest.self,
      at: control.appendingPathComponent("transition.json"), maximumBytes: NotebookArchiveFiles.maximumControlBytes)
    guard manifest.format == 1, manifest.target == target else { throw NotebookStorageError.invalidTransaction("activation target mismatch") }
    try manifest.content.validate()
    let receipt = try NotebookArchiveActivationReceipt(transitionID: manifest.transitionID,
      target: target, manifestSHA256: collaborationHash(manifest), content: manifest.content)
    let markerURL = root.appendingPathComponent(Self.markerName)
    let expectedMarker = NotebookArchiveActivationMarker(transitionID: manifest.transitionID,
      target: target, content: manifest.content)
    let marker = manager.fileExists(atPath: markerURL.path)
      ? try NotebookArchiveFiles.read(NotebookArchiveActivationMarker.self, at: markerURL) : nil
    do {
      let prepared = control.appendingPathComponent("candidate", isDirectory: true)
      if marker != expectedMarker {
        guard try NotebookArchiveFingerprint.read(root) == manifest.source,
          try NotebookArchiveFingerprint.read(prepared) == manifest.candidate else { throw NotebookStorageError.transactionConflict }
        let bytes = try availableBytes?(root) ?? (manager.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        guard bytes >= 64 * 1024 * 1024 else { throw NotebookStorageError.limitExceeded("activation_disk_reserve") }
        // Preparation may have happened on another device. Hash equality
        // proves copied bytes, not their durability on this destination.
        try syncLocalArchives([(root, manifest.source), (prepared, manifest.candidate)], control: control)
        try fault?(.afterLocalDurability)
        try fault?(.beforeSwap)
        guard try NotebookArchiveFingerprint.read(root) == manifest.source,
          try NotebookArchiveFingerprint.read(prepared) == manifest.candidate else { throw NotebookStorageError.transactionConflict }
        // Both directories exist on the same volume. There is no moment with
        // a missing root and no fallback to two non-atomic rename operations.
        guard renamex_np(root.path, prepared.path, UInt32(RENAME_SWAP)) == 0 else {
          throw NotebookArchiveFiles.failure("atomic archive exchange")
        }
        try fault?(.afterSwap)
      }
      guard try NotebookArchiveFingerprint.read(root) == manifest.candidate,
        try NotebookArchiveFingerprint.read(prepared) == manifest.source else { throw NotebookStorageError.transactionConflict }
      if marker == expectedMarker {
        // A prior exchange without its receipt recovers forward. Its files
        // must be durable here too; neither archive is exchanged back.
        try syncLocalArchives([(root, manifest.candidate), (prepared, manifest.source)], control: control)
        try fault?(.afterLocalDurability)
        guard try NotebookArchiveFingerprint.read(root) == manifest.candidate,
          try NotebookArchiveFingerprint.read(prepared) == manifest.source else { throw NotebookStorageError.transactionConflict }
      }
      try NotebookArchiveFiles.syncDirectory(root.deletingLastPathComponent())
      try NotebookArchiveFiles.syncDirectory(control)
      try fault?(.beforeReceipt)
      try NotebookArchiveFiles.publish(receipt, at: receiptURL)
      try fault?(.afterReceipt)
    }
    return try admissionStatus(root: root, receipt: receipt)
  }

  private func syncLocalArchives(_ archives: [(URL, NotebookArchiveFingerprint)], control: URL) throws {
    for (root, proof) in archives { try NotebookArchiveFiles.syncTree(root, proof: proof, syncFile: localSyncFile) }
    try localSyncFile(control.appendingPathComponent("transition.json"))
    try NotebookArchiveFiles.syncDirectory(control)
    try NotebookArchiveFiles.syncDirectory(control.deletingLastPathComponent())
  }

  /// Bounded waiting/cold-start check: never re-hashes SQLite after new input.
  public func admissionStatus(root: URL, receipt: NotebookArchiveActivationReceipt) throws -> NotebookArchiveLaunch {
    let manager = FileManager.default, control = Self.controlURL(for: root)
    try NotebookArchiveFiles.requireDirectory(root)
    try NotebookArchiveFiles.requireDirectory(control)
    let expected = NotebookArchiveActivationMarker(transitionID: receipt.transitionID, target: receipt.target, content: receipt.content)
    try receipt.content.validate()
    guard NotebookArchiveContentProof.isSHA256(receipt.manifestSHA256),
      try NotebookArchiveFiles.read(NotebookArchiveActivationMarker.self, at: root.appendingPathComponent(Self.markerName)) == expected,
      try NotebookArchiveFiles.read(NotebookArchiveActivationReceipt.self, at: control.appendingPathComponent("activation.json")) == receipt else {
      throw NotebookStorageError.invalidTransaction("activation receipt does not name the active archive")
    }
    let admissionURL = control.appendingPathComponent("admission.json")
    guard manager.fileExists(atPath: admissionURL.path) else { return .waitingForPair(receipt) }
    let admission = try NotebookArchiveFiles.read(NotebookArchiveAdmission.self, at: admissionURL)
    _ = try NotebookArchiveAdmission(receipts: admission.receipts, enrollment: admission.enrollment)
    guard admission.admits(receipt) else { throw NotebookStorageError.invalidTransaction("pair admission mismatch") }
    // A copied admission is not necessarily durable yet. Model/network
    // admission follows the destination's flush of this small control file.
    try localSyncFile(admissionURL)
    try NotebookArchiveFiles.syncDirectory(control)
    return .admitted(receipt)
  }
}
