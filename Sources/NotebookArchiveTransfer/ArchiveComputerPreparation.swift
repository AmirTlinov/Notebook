import Darwin
import Foundation
import NotebookCore

struct ArchiveComputerRequest: Codable {
  let currentIPad: String
  let freshMac: String
  let mac: NotebookArchiveTarget
}

struct ArchiveComputerReport: Codable {
  let source: NotebookArchiveEnrollmentSource
  let manifest: NotebookArchiveActivationManifest
  let installedApplicationsChanged: Bool
}

enum ArchiveComputerPreparation {
  /// A new-format current iPad backup is the only source. No legacy decoder,
  /// source replacement, copied actor, copied trust, or changed source journal.
  static func prepare(_ request: ArchiveComputerRequest, output: URL) throws -> ArchiveComputerReport {
    let manager = FileManager.default
    guard request.currentIPad.hasPrefix("/"), request.freshMac.hasPrefix("/"), output.path.hasPrefix("/"),
      request.mac.role == .mac, request.mac.bundleID == "com.amirtlinov.notebook.mac" else {
      throw ArchiveTransferError.invalidSource("an additional Mac requires its own installation identity")
    }
    let current = URL(fileURLWithPath: request.currentIPad), fresh = URL(fileURLWithPath: request.freshMac)
    let control = NotebookArchiveActivation.controlURL(for: current)
    let roots = [current, control, fresh, output].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    guard roots.enumerated().allSatisfy({ index, root in roots.enumerated().allSatisfy { other, path in
      index == other || (root != path && !root.hasPrefix(path + "/") && !path.hasPrefix(root + "/"))
    } }), !manager.fileExists(atPath: output.path),
      try manager.contentsOfDirectory(atPath: fresh.path).isEmpty else {
      throw ArchiveTransferError.invalidSource("the new Mac directory must be empty and all copies independent")
    }
    func read<T: Decodable>(_ type: T.Type, _ file: URL) throws -> T {
      let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
      guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) <= 16_384 else {
        throw ArchiveTransferError.invalidSource("invalid source admission")
      }
      return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }
    let sourceReceipt = try read(NotebookArchiveActivationReceipt.self, control.appendingPathComponent("activation.json"))
    let admission = try read(NotebookArchiveAdmission.self, control.appendingPathComponent("admission.json"))
    guard sourceReceipt.target.role == .iPad, admission.enrollment == nil,
      sourceReceipt.target.bundleID == "com.amirtlinov.notebook.preview",
      !admission.receipts.contains(where: { $0.target.actorID == request.mac.actorID }),
      try NotebookArchiveActivation().admissionStatus(root: current, receipt: sourceReceipt) == .admitted(sourceReceipt) else {
      throw ArchiveTransferError.invalidSource("the source must be an admitted current iPad, not a historical archive")
    }
    let before = try [current, control, fresh].map(NotebookArchiveFingerprint.read)
    let staging = output.deletingLastPathComponent().appendingPathComponent(".computer-" + UUID().uuidString)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: staging) }
    // Schema additions and inspection operate on a private working copy, never
    // open the backup in a writer merely to learn its current cursor.
    let copy = staging.appendingPathComponent("current"), replica = staging.appendingPathComponent("replica")
    try manager.copyItem(at: current, to: copy)
    guard try NotebookArchiveFingerprint.read(copy) == before[0] else { throw ArchiveTransferError.invalidSource("source changed during copy") }
    let store = NotebookStore(root: copy), cursor = try store.currentChangeCursor()
    let proof = try store.prepareDeviceSnapshot(at: replica, presence: store.loadPresence(), preservingLocalState: false,
      resumingFrom: sourceReceipt.target.actorID)
    guard try NotebookStore(root: replica).peerCursor(peerID: sourceReceipt.target.actorID, direction: .incoming) == cursor else {
      throw ArchiveTransferError.invalidSource("the new Mac must continue after the included iPad frontier")
    }
    let source = try NotebookArchiveEnrollmentSource(admission: admission, content: proof, cursor: cursor)
    let manifest = try NotebookArchiveActivation().prepare(source: fresh, candidate: replica,
      output: staging.appendingPathComponent("mac"), transitionID: UUID(), target: request.mac)
    guard manifest.content == proof, try [current, control, fresh].map(NotebookArchiveFingerprint.read) == before else {
      throw ArchiveTransferError.invalidSource("source or current admission changed")
    }
    let report = ArchiveComputerReport(source: source, manifest: manifest, installedApplicationsChanged: false)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: staging.appendingPathComponent("report.json"), options: .withoutOverwriting)
    try manager.removeItem(at: copy); try manager.removeItem(at: replica)
    guard renamex_np(staging.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
      throw ArchiveTransferError.invalidSource("could not publish the independent computer payload")
    }
    return report
  }
}
