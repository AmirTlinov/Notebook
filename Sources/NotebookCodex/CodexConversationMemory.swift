import Foundation
import NotebookCore

/// Credits for the native conversation owner's transient reads and immutable
/// transfers. Bodies remain in its states or the transfer itself.
final class CodexConversationMemory: @unchecked Sendable {
  static let bodyBytes = 48 * 1_048_576
  static let threadBodyBytes = 16 * 1_048_576
  static let previewBytes = 2048
  // One admitted read can overlap its native JSON frame, Foundation map,
  // formatted public item and canonical transfer encoding. Two peers can read;
  // native events and Stop/Approval do not enter this read admission.
  static let preparationBytes = 160 * 1_048_576
  static let maximumPreparationBytes = 2 * preparationBytes
  static let transferBytes = 16 * 1_048_576
  static let peerTransferBytes = CodexMessageTransfer.maximumBytes
  private let lock = NSLock()
  private var preparations: [UUID: Int] = [:]
  private struct Transfer { let peer: UUID; var bytes: Int }
  private var transfers: [UUID: Transfer] = [:]

  func reservePreparation() throws -> UUID {
    lock.lock(); defer { lock.unlock() }
    guard preparations.values.reduce(0,+) <= Self.maximumPreparationBytes - Self.preparationBytes else { throw CodexBridgeError.busy }
    let id = UUID(); preparations[id] = Self.preparationBytes; return id
  }
  func releasePreparation(_ id: UUID) {
    lock.lock(); defer { lock.unlock() }; preparations.removeValue(forKey:id)
  }
  func reserveTransfer(peer: UUID) throws -> Credit {
    lock.lock(); defer { lock.unlock() }
    // The old immutable value must actually drain before this peer can own
    // another. Disconnect/account change never resets outstanding credits.
    guard !transfers.values.contains(where: { $0.peer == peer }),
      transfers.values.reduce(0, { $0 + $1.bytes }) <= Self.transferBytes - Self.peerTransferBytes else {
      throw CodexBridgeError.busy
    }
    let id = UUID(); transfers[id] = .init(peer: peer, bytes: Self.peerTransferBytes)
    return Credit(owner: self, id: id)
  }
  private func shrinkTransfer(_ id: UUID, to bytes: Int) {
    lock.lock(); defer { lock.unlock() }
    guard let existing = transfers[id], bytes > 0, bytes <= existing.bytes else { return }
    transfers[id]?.bytes = bytes
  }
  private func releaseTransfer(_ id: UUID) {
    lock.lock(); defer { lock.unlock() }; transfers.removeValue(forKey: id)
  }
  var usage: (preparations: Int, transfers: Int, transferBytes: Int) {
    lock.lock(); defer { lock.unlock() }
    return (preparations.count, transfers.count, transfers.values.reduce(0, { $0 + $1.bytes }))
  }
  final class Credit: Sendable {
    private let owner: CodexConversationMemory
    private let id: UUID
    fileprivate init(owner: CodexConversationMemory, id: UUID) { self.owner = owner; self.id = id }
    func shrink(to bytes: Int) { owner.shrinkTransfer(id, to: bytes) }
    deinit { owner.releaseTransfer(id) }
  }
}

/// This is a transient native read, never a persisted transcript or wire body.
public enum CodexAuthoritativeMessageRead: Sendable {
  case searching(nextCursor: String)
  case transfer(CodexMessageTransfer)
}
