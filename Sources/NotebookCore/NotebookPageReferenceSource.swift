import Foundation

/// The complete physical identity and only the ink contributions admitted by
/// one page window. A later append or Undo replaces these exact contributions;
/// off-window material remains in the original owner digest.
struct NotebookPageReferenceBasis: Sendable {
  struct InkPart: Sendable { let header: JSONValue; let hash: String }
  let pageID: UUID
  let identity: NotebookReferenceIdentity
  let digest: Data
  let header: JSONValue
  let headerHash: String
  let ink: PageInkSource
  let parts: [UUID: InkPart]
  let lastInkMember: String?
  let sequenceFrontier: UInt64

  func revision(source: PageInkSource) throws -> String {
    if source.identity == ink.identity { return identity.revision }
    let original = try ink.drawing(), drawing = try source.drawing()
    guard drawing.baselinePNG == original.baselinePNG, drawing.baselineActionCount == original.baselineActionCount,
      original.actions.allSatisfy({ drawing.action(id: $0.id) != nil }) else {
      throw CollaborationError("capture_source_changed", "Указание потеряло сохранённые исходники чернил.")
    }
    let file = pageFile(pageID), owner = NotebookStore.referenceOwnerKey("page", pageID)
    var digest = digest, last = lastInkMember
    func replace(_ address: String, previous: String?, next: String?) {
      guard previous != next else { return }
      for hash in [previous, next].compactMap({ $0 }) {
        NotebookStore.xorReferenceDigest(&digest, NotebookStore.referenceContribution(address, hash))
      }
    }
    replace(file + "#", previous: headerHash,
      next: try collaborationHash(header.setting("drawingStamp", .encode(source.stamp))))
    for action in drawing.actions {
      let member = action.id.uuidString.lowercased(), address = file + "#/drawingData/actions/@" + member
      if let old = original.action(id: action.id) {
        guard old.settingVisibility(action.visibility) == action, let part = parts[action.id] else {
          throw CollaborationError("capture_source_changed", "Указание изменило сохранённое тело штриха.")
        }
        if old.visibility != action.visibility {
          let next = part.header.setting("isActive", .bool(action.isActive))
            .setting("stateStamp", try action.stateStamp.map(JSONValue.encode))
          replace(address, previous: part.hash, next: try collaborationHash(next))
        }
      } else {
        guard action.sequence > sequenceFrontier else {
          throw CollaborationError("capture_source_changed", "Новый штрих не следует сохранённому порядку листа.")
        }
        let rows = try NotebookRecordCodec.encode(.encode(action), file: file, address: address,
          parent: file + "#/drawingData", collection: "actions", member: member, position: Int(action.sequence - 1))
        for row in rows { replace(row.address, previous: nil, next: try collaborationHash(row.value)) }
        guard let painterMember = rows.first(where: { $0.address == address })?.value["id"]?.string else {
          throw NotebookStorageError.corruptRecord(address)
        }
        let edge = NotebookStore.referenceOrderAddress(owner: owner, group: "ink", from: last)
        replace(edge, previous: try last.map { _ in try collaborationHash(JSONValue.null) }, next: try collaborationHash(JSONValue.string(painterMember)))
        replace(NotebookStore.referenceOrderAddress(owner: owner, group: "ink", from: painterMember),
          previous: nil, next: try collaborationHash(JSONValue.null))
        last = painterMember
      }
    }
    return NotebookStore.referenceHash(Data(("reference-owner-v2\n" + owner + "\n").utf8) + digest)
  }
}

extension NotebookStore {
  func readPageReferenceBasis(pageID: UUID, ink: PageInkSource, sequenceFrontier: UInt64) throws -> NotebookPageReferenceBasis {
    let file = pageFile(pageID), owner = Self.referenceOwnerKey("page", pageID), database = currentSQL!
    guard let row = try database.rows("SELECT digest,hash FROM reference_owners WHERE owner_key=?", [.text(owner)]).first,
      let digest = row[0].blob, let revision = row[1].text,
      let header = try storedFragments(address: file + "#", descendants: false).first else {
      throw NotebookStorageError.corruptRecord(file)
    }
    func contribution(_ address: String) throws -> String {
      guard let value = try database.rows("SELECT hash FROM reference_contributions WHERE owner_key=? AND address=?",
        [.text(owner), .text(address)]).first?[0].text else { throw NotebookStorageError.corruptRecord(address) }
      return value
    }
    var parts: [UUID: NotebookPageReferenceBasis.InkPart] = [:]
    for action in try ink.drawing().actions {
      let address = file + "#/drawingData/actions/@" + action.id.uuidString.lowercased()
      guard let row = try storedFragments(address: address, descendants: false).first else { throw NotebookStorageError.corruptRecord(address) }
      parts[action.id] = .init(header: row.value, hash: try contribution(address))
    }
    let last = try database.rows("SELECT member FROM reference_element_order WHERE owner_key=? ORDER BY position DESC,member DESC LIMIT 1",
      [.text(owner + "|ink")]).first?[0].text
    return .init(pageID: pageID, identity: .init(target: .init(kind: .page, id: pageID), revision: revision),
      digest: digest, header: header.value.setting("collaboration", nil), headerHash: try contribution(file + "#"),
      ink: ink, parts: parts, lastInkMember: last, sequenceFrontier: sequenceFrontier)
  }
}

extension AgentPinnedSource {
  /// A native page window owns exact region material and a complete physical
  /// revision. It cannot masquerade as a serializable PageDocument.
  public static func capture(requestID: UUID, reference: CollaborationReference,
    page: any NotebookPagePresentationSource) throws -> Self {
    guard reference.target.kind == .page, reference.target.id == page.id,
      reference.revision == (try page.referenceRevision(elementID: reference.elementID)) else {
      throw CollaborationError("source_conflict", "Выделение и закреплённый исходник имеют разные версии.")
    }
    let region = reference.region ?? .init(x: 0, y: 0, width: page.size.width, height: page.size.height)
    guard page.coversMaterial(in: .init(x: region.x, y: region.y, width: region.width, height: region.height)) else {
      throw CollaborationError("source_incomplete", "Область указания ещё не подготовлена.")
    }
    let grant = try RequestGrant(mode: .question, references: [reference])
    let elements = reference.elementID.map { page.element(id: $0).map { [$0] } ?? [] } ?? page.elements
    let permitted = elements.filter {
      grant.permits(target: reference.target, elementID: $0.id, region: $0.frame, worldOrigin: nil)
    }
    let result = Self(id: reference.id, requestID: requestID, reference: reference,
      payload: .object(["reference": try .encode(reference), "paperSize": try .encode(page.size), "elements": try .encode(permitted)]))
    try result.validate()
    return result
  }
}
