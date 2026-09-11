import Foundation
import NotebookCore

/// The single Keychain value retains both peer credentials and consumption of
/// installer authority. Removing a peer never makes that authority reusable.
struct NotebookPairingTrustState: Codable, Equatable {
  var format = 1
  var installedGrantSHA256: String?
  var records: [NotebookTrustedPeer] = []

  func validate(for identity: NotebookTransportIdentity) throws {
    guard format == 1, records.count <= 8,
      installedGrantSHA256.map({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) ?? true,
      Set(records.map { $0.identity.deviceID }).count == records.count,
      records.allSatisfy({ $0.identity.isValid && $0.identity.workspaceID == identity.workspaceID
        && $0.identity.deviceID != identity.deviceID && $0.secret.count == 32 }) else {
      throw NotebookTransportError.identityMismatch
    }
  }

  mutating func install(_ grant: NotebookInstallationPairingGrant,
    receipt: NotebookArchiveActivationReceipt, admission: NotebookArchiveAdmission) throws {
    let peer = try grant.peer(for: receipt, admitted: admission)
    let fingerprint = try grant.fingerprint
    if let consumed = installedGrantSHA256 {
      guard consumed == fingerprint else { throw NotebookTransportError.identityMismatch }
      return
    }
    guard records.isEmpty else { throw NotebookTransportError.authenticationRequired }
    records = [.init(identity: .init(deviceID: peer.target.actorID, workspaceID: peer.content.workspaceID,
      displayName: peer.target.role == .iPad ? "iPad" : "Mac"), pairingID: grant.pairingID,
      secret: grant.secret, locallyConfirmed: true, remotelyConfirmed: true)]
    installedGrantSHA256 = fingerprint
  }
}

extension NotebookKeychainPairingStore {
  /// The app-private file is delivered by the authenticated installer, not by
  /// NearbySync. Receipt equality binds it to this exact admitted installation.
  /// Save and read-back precede deletion: interruption resumes without a second
  /// approval or restoring revoked credentials.
  func consumeInstallationGrant(root: URL, receipt: NotebookArchiveActivationReceipt) throws {
    guard activationID == receipt.transitionID else { throw NotebookTransportError.identityMismatch }
    guard let grant = try NotebookInstallationPairingGrant.read(root: root, receipt: receipt) else { return }
    let file = NotebookArchiveActivation.controlURL(for: root)
      .appendingPathComponent(NotebookInstallationPairingGrant.fileName)
    let identity = NotebookTransportIdentity(deviceID: receipt.target.actorID,
      workspaceID: receipt.content.workspaceID, displayName: receipt.target.role == .iPad ? "iPad" : "Mac")
    var state = try loadState(for: identity)
    try state.install(grant, receipt: receipt, admission: grant.admission)
    try saveState(state, for: identity)
    guard try loadState(for: identity) == state,
      try NotebookInstallationPairingGrant.read(root: root, receipt: receipt) == grant else {
      throw NotebookTransportError.storageUnavailable
    }
    try FileManager.default.removeItem(at: file)
  }
}
