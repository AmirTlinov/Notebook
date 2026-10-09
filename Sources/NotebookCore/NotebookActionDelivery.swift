import Foundation
import CryptoKit

private let notebookActionDeliveryDomain = "notebook.action-delivery.v1"

#if DEBUG
enum NotebookActionDeliveryObservation {
  struct Sample: Sendable {
    let actionID: UUID?
    let framedBytes: Int
  }

  private final class Box {
    let observer: @Sendable (Sample) -> Void
    init(_ observer: @escaping @Sendable (Sample) -> Void) { self.observer = observer }
  }
  private static let key = "notebook.action-delivery.debug-observer"

  static func withObserver<T>(_ observer: @escaping @Sendable (Sample) -> Void,
    operation: () throws -> T) rethrows -> T {
    let thread = Thread.current, previous = thread.threadDictionary[key]
    thread.threadDictionary[key] = Box(observer)
    defer {
      if let previous { thread.threadDictionary[key] = previous }
      else { thread.threadDictionary.removeObject(forKey: key) }
    }
    return try operation()
  }

  static var observer: (@Sendable (Sample) -> Void)? {
    (Thread.current.threadDictionary[key] as? Box)?.observer
  }
}
#endif

/// The same framing applies to an untouched raw historical body. Decoding it
/// as a typed receipt first would discard unknown authored JSON fields.
func notebookActionDeliveryVersion(_ receipt: JSONValue) throws -> String {
  let framed = JSONValue.object(["domain": .string(notebookActionDeliveryDomain), "receipt": receipt])
  #if DEBUG
  let observer = NotebookActionDeliveryObservation.observer
  let codecObserver = NotebookPublicationCodecObservation.observer
  if observer != nil || codecObserver != nil {
    let id = receipt["id"]?.string.flatMap { $0.utf16.count <= 36 ? UUID(uuidString: $0) : nil }
    return try collaborationHash(framed, observingEncodedBytes: { bytes in
      observer?(.init(actionID: id, framedBytes: bytes))
      codecObserver?(.init(phase: .deliveryEncode, encodedBytes: bytes))
    })
  }
  #endif
  return try collaborationHash(framed)
}

/// The publisher proves that its required receipt encoding is already canonical.
/// Hash the same sorted-key domain frame without another body encode or copy.
func notebookActionDeliveryVersion(canonicalReceiptBytes: Data, actionID: UUID) -> String {
  let prefix = Data(("{\"domain\":\"" + notebookActionDeliveryDomain + "\",\"receipt\":").utf8)
  let suffix = Data([125])
  var hash = SHA256()
  hash.update(data: prefix); hash.update(data: canonicalReceiptBytes); hash.update(data: suffix)
  let version = NotebookHexEncoding.encode(hash.finalize())
  #if DEBUG
  NotebookActionDeliveryObservation.observer?(.init(actionID: actionID,
    framedBytes: prefix.count + canonicalReceiptBytes.count + suffix.count))
  #endif
  return version
}

extension CollaborationReceipt {
  /// Identity of the saved effect, not a reconstruction of the raw request.
  /// The canonical receipt includes undo metadata even when both effects have
  /// no revised targets. Compute on the storage worker, never per camera frame.
  public func deliveryVersion() throws -> String {
    try notebookActionDeliveryVersion(.encode(self))
  }
}

extension DeviceActionReceipt {
  public func matches(_ action: CollaborationReceipt, version: String) -> Bool {
    id == action.id && actionVersion == version && revisions == action.revisions
  }
}

public struct NotebookActionArrivalDrain: Sendable {
  public let processed: Int
  public let published: Int
  public let hasMore: Bool
}

extension NotebookStore {
  /// The iPad acknowledges the exact immutable receipts read by this writer.
  /// A metadata-only undo still has a distinct version and gets a new arrival.
  @discardableResult
  public func acknowledgeReceivedActions(deviceID: UUID, limit: Int = 64) throws -> NotebookActionArrivalDrain {
    guard (1...64).contains(limit) else { throw NotebookStorageError.limitExceeded("action_arrival_batch") }
    return try commandTransaction(readAllowance: .agentCommand) {
      let database = currentSQL!
      let rows = try database.rows("SELECT m.address,m.receipt_hash,m.value,r.hash FROM action_read_models m JOIN records r ON r.address=m.address WHERE m.arrival_receipt_hash IS NOT m.receipt_hash ORDER BY m.address LIMIT ?", [.integer(Int64(limit))])
      var published = 0
      for row in rows {
        guard let address = row[0].text, let hash = row[1].text, hash == row[3].text,
          let data = row[2].blob else { throw NotebookStorageError.corruptRecord("pending action arrival") }
        let action = try JSONDecoder().decode(NotebookActionReadModel.self, from: data)
        let file = "collaboration/delivery/" + action.id.uuidString.lowercased() + ".json"
        let previous = try storedValue(file)?.decode(DeviceActionReceipt.self)
        if previous?.matches(action) != true {
          let receipt = DeviceActionReceipt(id: action.id, deviceID: deviceID,
            revisions: action.revisions, actionVersion: action.actionVersion)
          try publishRecords(writes: [file: try .encode(receipt)])
          published += 1
        }
        // Receipt and progress commit together. A later phase changes receipt_hash
        // in the admission owner and automatically re-enters the pending index.
        try database.run("UPDATE action_read_models SET arrival_receipt_hash=? WHERE address=? AND receipt_hash=?", [.text(hash), .text(address), .text(hash)])
      }
      let more = try !database.rows("SELECT 1 FROM action_read_models WHERE arrival_receipt_hash IS NOT receipt_hash LIMIT 1").isEmpty
      return .init(processed: rows.count, published: published, hasMore: more)
    }
  }

  /// Called inside the current writer, including the replication writer.
  /// Legacy bytes can be retained as history; they never acquire a version.
  func resolvedDeviceActionReceipt(_ receipt: DeviceActionReceipt,
    previous: DeviceActionReceipt?) throws -> DeviceActionReceipt? {
    guard receipt.actionVersion != nil else {
      if previous?.actionVersion != nil { return previous }
      return previous?.merging(receipt) ?? receipt
    }
    let action = try actionReadModel(receipt.id)
    guard receipt.matches(action) else { return previous }
    return previous?.matches(action) == true ? previous!.merging(receipt) : receipt
  }
}
