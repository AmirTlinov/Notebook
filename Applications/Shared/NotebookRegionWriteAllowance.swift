import Foundation
import NotebookCore

/// The existing writer's credit for an unresolved cut. This value describes
/// the captured source and possible result; it owns neither a queue nor memory.
/// Continuations carry the same bound before their predecessor is prepared.
struct NotebookRegionWriteAllowance: Sendable, Equatable {
  private struct Source: Sendable, Equatable {
    var retained: Int
    var bodies: Int
    var causal: Int
    var elements: Int
    var additional: Int
    var additionalCausal: Int
    var contour: Int
    var cuts: Bool
  }
  private let source: Source?
  static let maximum = Self(source: nil)
  private static let ceiling = NotebookElementWriteAllowance.maximumCost.bytes

  init(retainedBytes: Int, bodyBytes: Int, causalBytes: Int, elementCount: Int, contourCount: Int,
    predecessor: Self? = nil,materialized:Bool = false) {
    guard let predecessorSource = predecessor?.source ?? (predecessor == nil ?
      Source(retained: 0, bodies: 0, causal: 0, elements: 0, additional: 0, additionalCausal: 0, contour: 0, cuts: false) : nil) else {
      self = .maximum; return
    }
    source = Source(retained: Self.sum(retainedBytes, predecessorSource.additional, predecessorSource.additionalCausal),
      bodies: Self.sum(bodyBytes, predecessorSource.additional),
      causal: Self.sum(causalBytes, predecessorSource.additionalCausal),
      elements: min(64, elementCount + predecessorSource.elements),
      additional: predecessorSource.additional, additionalCausal: predecessorSource.additionalCausal, contour: contourCount, cuts: !materialized)
  }

  private init(source: Source?) { self.source = source }

  static func erasureBytes(_ masks:InkElementErasureMap)->Int {
    masks.retainedPayloadBytes
  }

  /// Waiting for an accepted predecessor may publish a newer immutable source.
  /// The retained bound permits that predecessor's additions, never an
  /// unbounded later publication. Check before materializing its bodies.
  func validateReplacement(_ next:Self) throws {
    guard let source else { _ = try next.cost();return }
    guard let fresh=next.source,fresh.retained<=source.retained,
      fresh.bodies<=source.bodies,fresh.causal<=source.causal,fresh.elements<=source.elements else {
      throw CollaborationError("resource_limit","Материал изменился во время подготовки. Повторите лассо.")
    }
  }

  /// A continued lift/delete moves the already chosen fragments. It cannot
  /// split that source again or silently borrow another materialization.
  func continuing() -> Self {
    guard var source else { return .maximum }
    let result = resultBound(source)
    // The predecessor owns its read root until materialization completes. A
    // continuation retains only that typed result, never the old journal/index.
    source.retained = Self.sum(result.bytes, result.causal)
    source.bodies = result.bytes
    source.causal = result.causal
    source.elements = result.parts
    source.additional = Self.sum(source.additional, result.bytes)
    source.additionalCausal = Self.sum(source.additionalCausal, result.causal)
    source.cuts = false
    return .init(source: source)
  }

  /// A new contour can select the accepted remainder while the prior worker
  /// is still running. Retain its prospective source size with that task.
  var prospective: Self {
    guard var source else { return .maximum }
    let result = resultBound(source)
    source.additional = Self.sum(source.additional, result.bytes)
    source.additionalCausal = Self.sum(source.additionalCausal, result.causal)
    source.elements = result.parts
    return .init(source: source)
  }

  func cost() throws -> NotebookPersistenceAdmission.Cost {
    guard let source else { return NotebookElementWriteAllowance.maximumCost }
    let result = resultBound(source)
    // JSONValue's dictionary/array entries, numeric nodes and escaped strings
    // are bounded separately from the typed capture. Thirty-two bytes per
    // source byte covers this schema's largest scalar/container expansion;
    // binary ink relations remain binary/base64 and never expand repetitions.
    let encoded = Self.sum(Self.product(result.bytes, 32), Self.product(result.parts, 16_384))
    // Source, materialization, draft and encoded operation coexist. The same
    // finish formula as the ready-plan meter includes the inverse and codecs.
    let resident = Self.sum(Self.product(result.bytes, 4), encoded, result.causal)
    let finish = Self.sum(Self.product(resident, 3), Self.product(encoded, 2), Self.product(result.causal, 12),
      131_072, Self.product(min(64, result.parts + source.elements), 4_096))
    // The captured cut and an admitted replacement can coexist until the
    // worker returns. Their source buffers are charged even when shared.
    let payload = Self.sum(Self.product(source.retained,2), resident)
    guard Self.sum(payload, finish) <= Self.ceiling else {
      throw CollaborationError("resource_limit","Подготовка изменения превышает резерв 192 МиБ. Уменьшите выделение.")
    }
    return .init(payloadBytes: payload, completionBytes: finish)
  }

  private func resultBound(_ source: Source) -> (bytes: Int, causal: Int, parts: Int) {
    let parts = max(1, min(32, source.cuts ? max(2, source.elements * 2) : source.elements))
    let contours = source.cuts ? Self.product(source.contour, parts, MemoryLayout<SpatialPoint>.stride * 2) : 0
    // A new fragment creates fixed field descriptors and one actor dot. Old
    // losing heads already belong to causal; an own successor cannot add a
    // foreign frontier. The 64 addressed-field envelope includes key buffers,
    // dictionaries, version values, their actor strings and UUID identities.
    let clocks = Self.product(parts, 64 * 1_024)
    return (Self.sum(Self.product(source.bodies, source.cuts ? 2 : 1), contours),
      Self.sum(source.causal, clocks), parts)
  }

  private static func sum(_ values: Int...) -> Int {
    values.reduce(0) { min(ceiling + 1, $0 + min(ceiling + 1, max(0, $1))) }
  }
  private static func product(_ values: Int...) -> Int {
    values.reduce(1) { result, next in
      guard result > 0, next > 0 else { return 0 }
      return result > ceiling / next ? ceiling + 1 : result * next
    }
  }
}

/// The per-surface material tail already owns readiness. Its immutable bound
/// travels with that same tail; there is no second admission or executor.
struct NotebookMaterialAdmission {
  let id: UUID
  let task: Task<Void, Never>
  let allowance: NotebookRegionWriteAllowance
  init(id: UUID, task: Task<Void, Never>, allowance: NotebookRegionWriteAllowance = .maximum) {
    self.id=id; self.task=task; self.allowance=allowance
  }
}
