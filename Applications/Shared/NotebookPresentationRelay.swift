import CryptoKit
import Foundation
import NotebookCore

/// Mac delivery of one transient presentation. A consumed view capability is
/// rotated even for SVG-only shows; evicted IDs and helper restarts cannot replay it.
@MainActor
final class NotebookPresentationRelay {
  private struct Entry {
    let digest: String
    let peer: UUID
    let session: UUID
    let deadline: Date
    var receipt: NotebookPresentationReceipt
  }
  private var view: NotebookPresentationView?
  private var presence: SessionPresence?
  private var entries: [UUID: Entry] = [:]
  private var order: [UUID] = []
  private var activeID: UUID?
  var send: ((NotebookPresentationMessage, UUID) -> Void)?

  func observe(_ envelope: PresenceEnvelope, from peer: UUID) {
    guard envelope.phase == .settled else { view = nil; return }
    if view?.deviceID != peer || view?.sessionID != envelope.sessionID || view?.sequence != envelope.sequence {
      view = .init(deviceID: peer, sessionID: envelope.sessionID, sequence: envelope.sequence)
    }
    presence = envelope.presence
  }

  func disconnect(_ peer: UUID) {
    if view?.deviceID == peer { view = nil; presence = nil }
    if let id = activeID, let entry = entries[id], entry.peer == peer {
      receive(.init(id: id, status: .unavailable, reason: "connection_lost"), from: peer)
    }
  }

  func handle(_ command: NotebookCommand) throws -> JSONValue {
    if let id = activeID, let entry = entries[id], entry.deadline < Date() {
      receive(.init(id: id, status: .unavailable, reason: "receipt_timeout"), from: entry.peer)
    }
    if let request = command.presentation {
      guard request.isValid else { throw CollaborationError("invalid_presentation", "Нужен короткий показ с конечной камерой и безопасным SVG.") }
      let digest = try Self.digest(request)
      if let entry = entries[request.id] {
        guard entry.digest == digest else { throw CollaborationError("presentation_id_conflict", "ID показа уже принадлежит другому сценарию.") }
        return try .encode(entry.receipt)
      }
      guard request.view == view, send != nil else {
        throw CollaborationError("view_changed", "Прочитайте текущий вид: iPad отключён, человек переместился или этот вид уже использован для показа.")
      }
      guard activeID == nil else { throw CollaborationError("presentation_busy", "Текущий показ ещё идёт. Дождитесь его либо остановите по ID.") }
      let receipt = NotebookPresentationReceipt(id: request.id, status: .sent)
      entries[request.id] = .init(digest: digest, peer: request.view.deviceID, session: request.view.sessionID,
        deadline: Date().addingTimeInterval(6 + request.steps.reduce(0) { $0 + $1.duration + 3 }), receipt: receipt)
      order.append(request.id)
      while order.count > 64 { entries.removeValue(forKey: order.removeFirst()) }
      activeID = request.id
      view = .init(deviceID: request.view.deviceID, sessionID: request.view.sessionID, sequence: request.view.sequence)
      send?(.play(request, expiresAt: Date().addingTimeInterval(5)), request.view.deviceID)
      return try .encode(receipt)
    }
    if let id = command.actionID {
      guard let entry = entries[id] else {
        return try .encode(NotebookPresentationReceipt(id: id, status: .unavailable, reason: "receipt_not_retained"))
      }
      if command.cancel == true, !entry.receipt.isTerminal { send?(.cancel(id: id, sessionID: entry.session), entry.peer) }
      return try .encode(entry.receipt)
    }
    return .object(["status": .string(view == nil ? "unavailable" : "ready"),
      "view": try .encode(view), "presence": try .encode(presence),
      "active": try .encode(activeID.flatMap { entries[$0]?.receipt })])
  }

  func receive(_ receipt: NotebookPresentationReceipt, from peer: UUID) {
    guard var entry = entries[receipt.id], entry.peer == peer, !entry.receipt.isTerminal else { return }
    entry.receipt = receipt; entries[receipt.id] = entry
    if receipt.isTerminal, activeID == receipt.id { activeID = nil }
  }

  static func digest(_ request: NotebookPresentationRequest) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }.joined()
  }
}
