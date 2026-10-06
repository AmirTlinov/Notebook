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
  static let maximumJSONDecodeBytes = 80 * 1_024 * 1_024
  static let maximumCost = NotebookPersistenceAdmission.Cost(
    payloadBytes: maximumPayloadBytes, completionBytes: 160 * 1_024 * 1_024)

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
    targets.capacity * MemoryLayout<InkElementTarget>.stride + targets.reduce(0) { $0 + $1.elementID.utf8.count * 2 }
  }

  static func cost(_ action: PageInkAction) throws -> NotebookPersistenceAdmission.Cost {
    try cost(measurements: action.samples.count,
      worldMeasurements: action.samples.isWorld ? action.samples.count : 0,
      payloadBytes: action.samples.payloadBytes + targetBytes(action.elementTargets ?? []) + MemoryLayout<PageInkAction>.stride,
      targets: action.elementTargets ?? [], spans: 1)
  }

  static func cost(_ spans: [SpatialInkSpan]) throws -> NotebookPersistenceAdmission.Cost {
    let targets = spans.flatMap { $0.elementTargets ?? [] }
    return try cost(measurements: spans.reduce(0) { $0 + $1.samples.count },
      worldMeasurements: spans.reduce(0) { $0 + ($1.samples.isWorld ? $1.samples.count : 0) },
      payloadBytes: spans.reduce(MemoryLayout<SpatialInkAction>.stride) {
        $0 + $1.samples.payloadBytes + MemoryLayout<SpatialInkSpan>.stride + targetBytes($1.elementTargets ?? [])
      }, targets: targets, spans: spans.count)
  }

  static func stateCost(entries: Int) -> NotebookPersistenceAdmission.Cost {
    .init(payloadBytes: entries * (MemoryLayout<UUID>.stride + MemoryLayout<PageInkVisibility>.stride + 64),
      // Visibility changes read the previous addressed header. Legacy eraser
      // targets remain in that JSON, even though no sample body changes.
      completionBytes: NotebookNativeWriteAllowance.maximumExecutionBytes)
  }

  /// Validate the prospective exact contribution before replacing the accepted
  /// contact. The cached target schema is the same one charged again at lift.
  static func contactLimit(measurements: Int, worldMeasurements: Int, targetCount: Int,
    targetPayloadBytes: Int, targetWriteAllowance: InkElementTarget.WriteAllowance, spans: Int) -> Limit? {
    do {
      _ = try cost(measurements: measurements, worldMeasurements: worldMeasurements,
        payloadBytes: measurements * MemoryLayout<SpatialInkSample>.stride * 2 + targetPayloadBytes + spans * 512,
        targetCount: targetCount, targetPayloadBytes: targetPayloadBytes,
        targetWriteAllowance: targetWriteAllowance, spans: spans)
      return nil
    } catch let limit as Limit { return limit }
    catch { return .bytes }
  }

  private static func cost(measurements: Int, worldMeasurements: Int, payloadBytes: Int, targets: [InkElementTarget],
    spans: Int) throws -> NotebookPersistenceAdmission.Cost {
    var metadata = InkElementTarget.WriteAllowance.zero
    for target in targets { metadata.add(target.writeAllowance) }
    return try cost(measurements: measurements, worldMeasurements: worldMeasurements, payloadBytes: payloadBytes,
      targetCount: targets.count, targetPayloadBytes: targetBytes(targets), targetWriteAllowance: metadata, spans: spans)
  }

  private static func cost(measurements: Int, worldMeasurements: Int, payloadBytes: Int, targetCount: Int,
    targetPayloadBytes: Int, targetWriteAllowance metadata: InkElementTarget.WriteAllowance,
    spans: Int) throws -> NotebookPersistenceAdmission.Cost {
    guard measurements <= maximumMeasurements else { throw Limit.measurements }
    guard targetCount <= maximumTargets else { throw Limit.targets }
    guard targetPayloadBytes <= maximumTargetBytes else { throw Limit.bytes }
    guard spans <= maximumSpans else { throw Limit.spans }
    guard payloadBytes <= maximumPayloadBytes else { throw Limit.bytes }
    guard worldMeasurements >= 0, worldMeasurements <= measurements else { throw Limit.bytes }
    // Live relations use <=256-event leaves and balanced pair nodes. Primitive
    // binary samples need65/97bytes for paper/world;512bytes per node covers all
    // field tags, headers and relation framing without expanding a generator.
    let nodes = 2 * ((measurements + 255) / 256) + 2 * spans
    let binary = spans * 54 + (measurements - worldMeasurements) * 65 + worldMeasurements * 97 + nodes * 512
    let wire = ((binary + 2) / 3) * 4 + metadata.wireBytes + spans * 1_024
    let tokens = metadata.jsonTokens + spans * 64
    let jsonDecode = wire * 8 + tokens * 512
    // One new contact also remains decodable through the existing80 MiB
    // transfer and96 MiB addressed-command cuts. Targets stay JSON metadata
    // after measurement bodies become blobs, so their token cost is explicit.
    guard jsonDecode <= maximumJSONDecodeBytes else { throw Limit.bytes }
    // The512/event capture bound includes raw/processed Pencil point objects,
    // doubled COW measurement buffers, force estimates and their array/hash
    // entries. Finish separately pays Foundation JSON map/tree, NIM/base64
    // buffers, simultaneous metadata copies, bounded SQL/TEMP and ink cache.
    let completion = measurements * 512 + targetPayloadBytes * 3 + binary * 2 + wire * 2
      + jsonDecode + metadata.retainedBytes * 2 + 8 * 1_024 * 1_024 + spans * 1_024
    let cost = NotebookPersistenceAdmission.Cost(payloadBytes: payloadBytes, completionBytes: completion)
    guard cost.payloadBytes <= maximumCost.payloadBytes, cost.completionBytes <= maximumCost.completionBytes,
      cost.bytes <= maximumCost.bytes else { throw Limit.bytes }
    return cost
  }
}
