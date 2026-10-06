import Foundation
import NotebookCore

/// The native contact's finite capture/finish contract. Existing imported ink
/// keeps its source-format limits; these allowances apply to new live input.
enum NotebookInkWriteAllowance {
  static let maximumMeasurements = 65_536
  static let maximumTargets = 4_096
  static let maximumSpans = 1_024
  static let maximumPredictions = 256
  static let maximumTargetBytes = 8 * 1_024 * 1_024
  static let maximumPayloadBytes = 32 * 1_024 * 1_024
  static let maximumCost = NotebookPersistenceAdmission.Cost(
    payloadBytes: maximumPayloadBytes, completionBytes: 96 * 1_024 * 1_024)

  enum Limit: Error, LocalizedError {
    case measurements, targets, spans, bytes
    var errorDescription: String? {
      switch self {
      case .measurements: "Штрих завершён у предела 65 536 измерений. Начните следующий."
      case .targets: "Ластик завершён у предела 4 096 объектов. Начните следующий контакт."
      case .spans: "Штрих завершён у предела 1 024 участков. Начните следующий."
      case .bytes: "Контакт достиг зарезервированного объёма. Начните следующий."
      }
    }
  }

  static func targetBytes(_ targets: [InkElementTarget]) -> Int {
    targets.reduce(0) { $0 + MemoryLayout<InkElementTarget>.stride + $1.elementID.utf8.count }
  }

  static func permitsTargets(_ targets: [InkElementTarget]) -> Bool {
    targets.count <= maximumTargets && targetBytes(targets) <= maximumTargetBytes
  }

  static func targetLimit(_ targets: [InkElementTarget], priorCount: Int = 0,
    priorBytes: Int = 0) -> Limit? {
    if targets.count > maximumTargets - priorCount { return .targets }
    if targetBytes(targets) > maximumTargetBytes - priorBytes { return .bytes }
    return nil
  }

  static func cost(_ action: PageInkAction) throws -> NotebookPersistenceAdmission.Cost {
    try cost(measurements: action.samples.count,
      payloadBytes: action.samples.payloadBytes + targetBytes(action.elementTargets ?? []) + MemoryLayout<PageInkAction>.stride,
      targets: action.elementTargets ?? [], spans: 1)
  }

  static func cost(_ spans: [SpatialInkSpan]) throws -> NotebookPersistenceAdmission.Cost {
    let targets = spans.flatMap { $0.elementTargets ?? [] }
    return try cost(measurements: spans.reduce(0) { $0 + $1.samples.count },
      payloadBytes: spans.reduce(MemoryLayout<SpatialInkAction>.stride) {
        $0 + $1.samples.payloadBytes + MemoryLayout<SpatialInkSpan>.stride + targetBytes($1.elementTargets ?? [])
      }, targets: targets, spans: spans.count)
  }

  static func stateCost(entries: Int) -> NotebookPersistenceAdmission.Cost {
    .init(payloadBytes: entries * (MemoryLayout<UUID>.stride + MemoryLayout<PageInkVisibility>.stride + 64),
      completionBytes: 16_384 + entries * 1_024)
  }

  private static func cost(measurements: Int, payloadBytes: Int, targets: [InkElementTarget],
    spans: Int) throws -> NotebookPersistenceAdmission.Cost {
    guard measurements <= maximumMeasurements else { throw Limit.measurements }
    guard permitsTargets(targets) else { throw Limit.targets }
    guard spans <= maximumSpans else { throw Limit.spans }
    guard payloadBytes <= maximumPayloadBytes else { throw Limit.bytes }
    // The payload is the actual sealed relation/metadata allocation. The
    // simultaneous raw/routed/prepared/codec/history workspace is pessimistic:
    // 1 KiB per event, three target bodies, 1 KiB per span, and fixed SQL buffers.
    let completion = 16_384 + measurements * 1_024 + targetBytes(targets) * 3 + spans * 1_024
    let cost = NotebookPersistenceAdmission.Cost(payloadBytes: payloadBytes, completionBytes: completion)
    guard cost.bytes <= maximumCost.bytes else { throw Limit.bytes }
    return cost
  }
}
