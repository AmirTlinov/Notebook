import CryptoKit
import Darwin
import Foundation

/// An authenticated installer transports this one-use credential to both app
/// containers after collecting their actual activation receipts. Discovery is
/// never authority to issue a grant. The runtime consumes it into device-only
/// Keychain storage before starting either model or network.
public struct NotebookInstallationPairingGrant: Codable, Equatable, Sendable {
  public static let fileName = "installation-pairing.json"
  public let format: Int
  public let admission: NotebookArchiveAdmission
  public let pairingID: UUID
  public let secret: Data

  public init(admission: NotebookArchiveAdmission) throws {
    self.admission = try NotebookArchiveAdmission(receipts: admission.receipts)
    format = 1; pairingID = UUID()
    secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
  }

  public func publish(at file: URL) throws {
    guard let local = admission.receipts.first else { throw NotebookStorageError.invalidTransaction("pairing requires an admitted pair") }
    _ = try peer(for: local, admitted: admission)
    try NotebookArchiveFiles.publish(self, at: file, withoutOverwriting: true)
  }

  public var fingerprint: String { get throws { try collaborationHash(self) } }

  public static func read(root: URL, receipt: NotebookArchiveActivationReceipt) throws -> Self? {
    let control = NotebookArchiveActivation.controlURL(for: root)
    let file = control.appendingPathComponent(fileName)
    var status = stat()
    if lstat(file.path, &status) != 0 {
      if errno == ENOENT { return nil }
      throw NotebookArchiveFiles.failure("inspect installation pairing grant")
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw NotebookStorageError.invalidTransaction("installation pairing grant must be a regular private file")
    }
    guard try NotebookArchiveActivation().admissionStatus(root: root, receipt: receipt) == .admitted(receipt) else {
      throw NotebookStorageError.invalidTransaction("installation pairing requires both activated devices")
    }
    let grant = try NotebookArchiveFiles.read(Self.self, at: file)
    let admitted = try NotebookArchiveFiles.read(NotebookArchiveAdmission.self, at: control.appendingPathComponent("admission.json"))
    _ = try grant.peer(for: receipt, admitted: admitted)
    return grant
  }

  public func peer(for receipt: NotebookArchiveActivationReceipt,
    admitted: NotebookArchiveAdmission) throws -> NotebookArchiveActivationReceipt {
    let checked = try NotebookArchiveAdmission(receipts: admitted.receipts)
    guard format == 1, secret.count == 32, admission == checked,
      checked.receipts.contains(receipt), let peer = checked.receipts.first(where: { $0 != receipt }) else {
      throw NotebookStorageError.invalidTransaction("installation pairing does not name the admitted device pair")
    }
    return peer
  }
}
