import Foundation

/// Immutable input for one request. This is a redacted physical fragment, not
/// a path to the latest document or permission to read the current selection.
public struct AgentPinnedSource: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let requestID: UUID
  public let reference: CollaborationReference
  public let payload: JSONValue
  public var image: AgentPinnedImage?

  public func withVisual(_ image: AgentPinnedImage?, unavailable: String? = nil) throws -> Self {
    var content = payload.object
    content["visual"] = .object(["status": .string(image == nil ? "unavailable" : "source_pixels"),
      "reason": unavailable.map { .string(String($0.prefix(2_048))) } ?? .null])
    let value = Self(id: id, requestID: requestID, reference: reference, payload: .object(content), image: image)
    try value.validate(); return value
  }

  public func validate() throws {
    guard id == reference.id, payload.isValid,
      try NotebookStore.storageEncoder.encode(payload).count <= 1_048_576 else {
      throw CollaborationError("invalid_request_source", "Закреплённый исходник превышает допустимый размер.")
    }
    try RequestGrant(mode: .question, references: [reference]).validate()
    try image?.validate(reference: reference)
  }

  public static func capture(requestID: UUID, reference: CollaborationReference,
    files: [String: JSONValue]) throws -> Self {
    guard try NotebookStore.referenceRevision(target: reference.target, elementID: reference.elementID, files: files) == reference.revision else {
      throw CollaborationError("source_conflict", "Выделение и закреплённый исходник имеют разные версии.")
    }
    let grant = try RequestGrant(mode: .question, references: [reference])
    let target = reference.target
    let suffix = target.id.uuidString.lowercased() + ".json"
    let elements: [JSONValue]
    var payload: [String: JSONValue] = ["reference": try .encode(reference)]
    switch target.kind {
    case .codeFragment:
      guard let fragment = files[codeFragmentFile(target.id)], reference.region == nil else { throw missing() }
      payload["code"] = fragment; elements = []
    case .page:
      guard let page = files["pages/" + suffix] else { throw missing() }
      elements = page["elements"]?.array ?? []
      payload["paperSize"] = page["size"]
      // Ink is represented by an exact regional image, never by raw strokes
      // whose endpoints could disclose content outside an area permission.
    case .document:
      guard let document = files["documents/" + suffix] else { throw missing() }
      if let blockID = reference.elementID {
        guard let block = document["blocks"]?.array.first(where: { $0.memberIdentity == collaborationIdentity(blockID) }) else { throw missing() }
        payload["block"] = block
        if let state = files["document-states/" + suffix]?["records"]?.array.first(where: { $0.memberIdentity == collaborationIdentity(blockID) }) {
          payload["state"] = state["value"]
        }
      }
      // Pagination geometry alone does not authorize every program in a file.
      elements = []
    case .board, .cover:
      let boardID = target.kind == .board ? target.id : target.boardID!
      guard let node = files["board.json"]?["boards"]?.array.first(where: {
        $0["id"]?.string?.lowercased() == boardID.uuidString.lowercased()
      }) else { throw missing() }
      let surface = target.kind == .board ? SurfaceID.board(target.id) : .cover(target.id)
      elements = try (node["board"]?["elements"]?.array ?? []).filter {
        try $0["surface"]?.decode(SurfaceID.self) == surface
      }
    case .workspace: throw CollaborationError("grant_denied", "Запрос не получает весь архив.")
    }
    payload["elements"] = try .array(elements.filter { value in
      guard let id = value["id"]?.string, let frame = value["frame"] else { return false }
      return try grant.permits(target: target, elementID: id, region: frame.decode(PageRect.self),
        worldOrigin: value["worldOrigin"]?.decode(WorldPoint.self))
    })
    let result = Self(id: reference.id, requestID: requestID, reference: reference, payload: .object(payload))
    try result.validate(); return result
  }

  private static func missing() -> CollaborationError { .init("source_missing", "Закреплённый владелец отсутствует.") }
}
