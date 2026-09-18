import Foundation

/// Canonical source and state keep their native identity after catalogue
/// retirement. They are not a second archive, live item or permission to write.
struct NotebookRetiredDocumentBaseline {
  let source: NotebookStoredFragment
  let state: NotebookStoredFragment
}

extension NotebookStore {
  func documentSourceHeader(_ root: NotebookStoredFragment, id: UUID) throws -> DocumentDocument {
    let file = documentFile(id), address = file + "#"
    let document = try NotebookRecordCodec.decode([root], root: address).decode(DocumentDocument.self)
    guard document.id == id, document.isValid,
      try NotebookRecordCodec.encode(.encode(document), file: file) == [root] else {
      throw NotebookStorageError.corruptRecord(address)
    }
    return document
  }

  /// A clock key alone is never a document. The typed source/state pair is the
  /// existing kind discriminator; these keys bind it to a retired catalogue ID.
  private func hasRetiredDocumentKind(_ id: UUID) throws -> Bool {
    let item = id.uuidString.lowercased()
    guard try readItemHeader(id) == nil,
      try storedFragments(address: "workspace.json#/pageOrders/@" + item, descendants: false).isEmpty,
      try storedFragments(address: "board.json#/boards/@" + item, descendants: false).isEmpty else { return false }
    for field in ["exists", "kind"] {
      let key = fieldKey(["items", item, field]), address = "workspace.json#/collaboration/fields/@" + fieldKey([key])
      guard let row = try storedFragments(address: address, descendants: false).first else { return false }
      let version = try row.value.decode(ContentFieldVersion.self)
      guard version.isValid,
        row == NotebookStoredFragment(address: address, file: "workspace.json", parent: "workspace.json#",
          collection: "collaboration/fields", member: key, position: 0, value: try .encode(version), collections: []) else {
        throw NotebookStorageError.corruptRecord("retired document kind")
      }
    }
    return true
  }

  /// Bounded header check only. Undo restores membership, not these already
  /// admitted programs/state values, so it never decodes all their bodies.
  func requireRetiredDocumentBaseline(itemID: UUID) throws -> NotebookRetiredDocumentBaseline {
    guard try hasRetiredDocumentKind(itemID) else {
      throw NotebookStorageError.invalidTransaction("retired document owner is not admitted")
    }
    let sourceAddress = documentFile(itemID) + "#", stateAddress = stateFile(itemID) + "#"
    let rows = try boundedStoredFragments([(sourceAddress, false), (stateAddress, false)], maximumCount: 2,
      maximumBytes: 2 * 1_048_576, budget: "retired_document_headers")
    guard let source = rows.first(where: { $0.address == sourceAddress }),
      let state = rows.first(where: { $0.address == stateAddress }) else {
      throw NotebookStorageError.invalidTransaction("retired document source/state pair is not admitted")
    }
    _ = try documentSourceHeader(source, id: itemID)
    _ = try documentStateHeader(state, id: itemID)
    return .init(source: source, state: state)
  }

  func documentSourceOwnerID(_ id: UUID) throws -> UUID? {
    if let live = try readItemHeader(id) { return live.kind == .document ? id : nil }
    guard try hasRetiredDocumentKind(id), try hasStoredValue(documentFile(id)), try hasStoredValue(stateFile(id)) else { return nil }
    _ = try requireRetiredDocumentBaseline(itemID: id)
    return id
  }

  /// Both native mergers use this admission, then validate every newly received
  /// source/state atom themselves. The outer transaction admits the pair or
  /// neither file. Neither an earlier metadata claim nor one root is a grant.
  func admitsReplicatedRetiredDocumentPair(itemID: UUID, records: NotebookIncomingRecords) throws -> Bool {
    guard try hasRetiredDocumentKind(itemID) else { return false }
    if try hasStoredValue(documentFile(itemID)), try hasStoredValue(stateFile(itemID)) {
      _ = try requireRetiredDocumentBaseline(itemID: itemID)
      return true
    }
    let id = itemID.uuidString.lowercased()
    for field in ["exists", "kind"] {
      let key = fieldKey(["items", id, field])
      guard try records.fragment("workspace.json#/collaboration/fields/@" + fieldKey([key])) != nil,
        try records.field(parent: "workspace.json#", collection: "collaboration/fields", key: key, delivered: true) != nil else { return false }
    }
    guard let source = try records.fragment(documentFile(itemID) + "#"),
      let state = try records.fragment(stateFile(itemID) + "#") else { return false }
    _ = try documentSourceHeader(source, id: itemID)
    _ = try documentStateHeader(state, id: itemID)
    return true
  }
}
