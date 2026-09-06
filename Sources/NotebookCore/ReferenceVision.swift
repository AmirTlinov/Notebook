import Foundation

public struct ReferenceStatus: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable { case current, changed, checking, reviewRequired = "review_required", targetMissing = "target_missing" }
  public let status: State
  public let currentRevision: String?
  public let fingerprint: String?
  public init(_ status: State, currentRevision: String? = nil, fingerprint: String? = nil) {
    self.status = status; self.currentRevision = currentRevision; self.fingerprint = fingerprint
  }
}

private struct ReferenceBaseline: Codable {
  let reference: CollaborationReference
  let fingerprint: String
}

extension NotebookStore {
  /// A regional source is compared only after the common renderer has examined its final pixels.
  /// A missing baseline is never replaced by the newer source and called fresh.
  public func referenceStatus(_ reference: CollaborationReference, prepareRender: Bool = true) throws -> ReferenceStatus {
    let files: [String: JSONValue]
    let revision: String
    do {
      files = try referenceSourceFiles(target: reference.target)
      revision = try Self.referenceRevision(target: reference.target, elementID: reference.elementID, files: files)
    }
    catch let error as CollaborationError where error.code == "target_missing" { return .init(.targetMissing) }
    let result = try referenceStatus(reference, currentRevision: revision)
    if result.status == .checking, prepareRender {
      _ = try requestTargetRender(target: reference.target,
        expectedRevision: Self.targetContentRevision(target: reference.target, files: files),
        region: reference.region, worldOrigin: reference.worldOrigin, pageIndex: reference.pageIndex ?? 0)
    }
    return result
  }

  /// Uses the caller's completed content cut. Reading small render proofs does
  /// not acquire the content mutation lock or serialize the workspace again.
  public func referenceStatus(_ reference: CollaborationReference, currentRevision revision: String) throws -> ReferenceStatus {
    guard reference.region != nil, reference.elementID == nil, reference.target.kind != .workspace else {
      return .init(revision == reference.revision ? .current : .changed, currentRevision: revision)
    }
    let identity: JSONValue = .object(["target": try .encode(reference.target), "region": try .encode(reference.region),
      "origin": try .encode(reference.worldOrigin), "page": .number(Double(reference.pageIndex ?? 0)), "source": .string(reference.revision)])
    let key = try collaborationHash(identity)
    let path = root.appendingPathComponent("previews/reference-baselines/\(key).json")
    var baseline = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(ReferenceBaseline.self, from: $0) }
    if let stored = baseline?.reference,
      stored.target != reference.target || stored.region != reference.region || stored.worldOrigin != reference.worldOrigin
        || (stored.pageIndex ?? 0) != (reference.pageIndex ?? 0) || stored.revision != reference.revision { baseline = nil }
    let requests = try targetRenderRequests().filter {
      $0.target == reference.target && $0.region == reference.region && $0.worldOrigin == reference.worldOrigin && $0.pageIndex == (reference.pageIndex ?? 0)
    }
    func proof(_ revision: String) -> String? {
      guard let request = requests.first(where: { $0.sourceRevision == revision }),
        let bytes = try? Data(contentsOf: targetReceiptURL(request.id)),
        let receipt = try? JSONDecoder().decode(TargetRenderReceipt.self, from: bytes),
        receipt.request == request, receipt.status == "ready", receipt.diagnostics.isEmpty else { return nil }
      return receipt.referenceFingerprint
    }
    if baseline == nil, let fingerprint = proof(reference.revision) {
      baseline = .init(reference: reference, fingerprint: fingerprint)
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(baseline!).write(to: path, options: .atomic)
    }
    if let baseline, let current = proof(revision) {
      return .init(current == baseline.fingerprint ? .current : .changed, currentRevision: revision, fingerprint: current)
    }
    guard baseline != nil || revision == reference.revision else { return .init(.reviewRequired, currentRevision: revision) }
    return .init(.checking, currentRevision: revision)
  }

  /// Ink is supplied by the same final raster as iPad. Position is used to select
  /// intersecting content, not as a replacement for its semantic identity.
  public static func regionalFingerprint(_ request: TargetRenderRequest, inkFingerprint: String,
    files: [String: JSONValue]) throws -> String {
    let target = request.target
    guard let region = request.region else { throw CollaborationError("invalid_reference", "Нужна локальная область.") }
    var elements: [JSONValue] = []
    if target.kind == .page { elements = files["pages/\(target.id.uuidString.lowercased()).json"]?["elements"]?.array ?? [] }
    if target.kind == .cover || target.kind == .board {
      let boardID = target.boardID ?? target.id
      elements = files["board.json"]?["boards"]?.array.first { $0.memberIdentity == boardID.uuidString.lowercased() }?["board"]?["elements"]?.array.filter {
        $0["surface"]?["kind"]?.string == target.kind.rawValue && $0["surface"]?["ownerID"]?.string.flatMap(UUID.init(uuidString:)) == target.id
      } ?? []
    }
    let considered = try elements.filter { element in
      guard let value = element["frame"] else { return false }
      let frame = try value.decode(PageRect.self)
      let delta: SpatialPoint
      if target.kind == .board {
        let origin = try element["worldOrigin"].map { try $0.decode(WorldPoint.self) } ?? .zero
        delta = (request.worldOrigin ?? .zero).delta(to: origin)
      } else { delta = .zero }
      return frame.x + delta.x < region.x + region.width && frame.x + frame.width + delta.x > region.x
        && frame.y + delta.y < region.y + region.height && frame.y + frame.height + delta.y > region.y
    }.map { $0.setting("frame", nil).setting("worldOrigin", nil).setting("stamp", nil).setting("collaboration", nil) }
    return try collaborationHash(JSONValue.object(["ink": .string(inkFingerprint), "elements": .array(considered)]))
  }
}
