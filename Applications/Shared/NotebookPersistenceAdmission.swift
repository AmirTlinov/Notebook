import Foundation

/// Capacity belongs to the accepted writer. A contact reserves its worst finish
/// before taking input; lift transfers that credit without asking for new memory.
@MainActor
final class NotebookPersistenceAdmission {
  struct Limits {
    var maximumBytes = 256 * 1_024 * 1_024
    var maximumOperations = 512
  }

  struct Cost: Equatable, Sendable {
    let payloadBytes: Int
    let completionBytes: Int
    var bytes: Int { payloadBytes + completionBytes }
    static let zero = Cost(payloadBytes: 0, completionBytes: 0)

    init(payloadBytes: Int, completionBytes: Int = 0) {
      precondition(payloadBytes >= 0 && completionBytes >= 0 && payloadBytes <= Int.max - completionBytes)
      self.payloadBytes = payloadBytes; self.completionBytes = completionBytes
    }
  }

  struct Reservation: Hashable, Sendable {
    fileprivate let owner: UUID
    fileprivate let id: UUID
  }

  private struct Allocation {
    var cost: Cost
    var accepted = false
  }

  let limits: Limits
  private let id = UUID()
  private var allocations: [UUID: Allocation] = [:]
  private(set) var occupiedBytes = 0
  private(set) var acceptedPayloadBytes = 0
  private(set) var acceptedCompletionBytes = 0
  var operationCount: Int { allocations.count }
  var reservedContactCount: Int { allocations.values.reduce(0) { $0 + ($1.accepted ? 0 : 1) } }

  init(limits: Limits) {
    precondition(limits.maximumBytes >= 0 && limits.maximumOperations >= 0)
    self.limits = limits
  }

  func reserve(_ cost: Cost) -> Reservation? {
    guard allocations.count < limits.maximumOperations,
      cost.bytes <= limits.maximumBytes - occupiedBytes else { return nil }
    let reservation = Reservation(owner: id, id: UUID())
    allocations[reservation.id] = .init(cost: cost)
    occupiedBytes += cost.bytes
    return reservation
  }

  /// Returns an owned charge that the FIFO releases only at a final outcome.
  /// A caller cannot steal another workspace's reserve or consume it twice.
  func transfer(_ reservation: Reservation, retaining retainedCost: Cost? = nil) throws -> UUID {
    guard reservation.owner == id, let reserved = allocations[reservation.id], !reserved.accepted else {
      throw NotebookPersistenceQueue.Failure(message: "Контакт превышает зарезервированную ёмкость сохранения.")
    }
    let cost = retainedCost ?? reserved.cost
    guard cost.bytes <= reserved.cost.bytes else { throw capacityFailure() }
    occupiedBytes -= reserved.cost.bytes - cost.bytes
    acceptedPayloadBytes += cost.payloadBytes
    acceptedCompletionBytes += cost.completionBytes
    allocations[reservation.id] = .init(cost: cost, accepted: true)
    return reservation.id
  }

  /// A nonmutating source/encoding worker owns its credit until actual worker
  /// completion. Abandoning its UI wait cannot release these resident bodies.
  func resize(_ reservation: Reservation, to cost: Cost) throws {
    guard reservation.owner == id, let allocation = allocations[reservation.id], !allocation.accepted,
      cost.bytes <= allocation.cost.bytes else { throw capacityFailure() }
    occupiedBytes -= allocation.cost.bytes - cost.bytes
    allocations[reservation.id] = .init(cost: cost)
  }

  /// Optional preparation learns the expanded source before allocating its
  /// next phase. Only this still-unaccepted lease may grow, immediately or not
  /// at all; neither a FIFO slot nor a completed contact can renew its finish.
  func extendPreparation(_ reservation: Reservation, to cost: Cost) throws {
    guard reservation.owner == id, let allocation = allocations[reservation.id], !allocation.accepted,
      cost.bytes >= allocation.cost.bytes,
      cost.bytes - allocation.cost.bytes <= limits.maximumBytes - occupiedBytes else { throw capacityFailure() }
    occupiedBytes += cost.bytes - allocation.cost.bytes
    allocations[reservation.id] = .init(cost: cost)
  }

  /// Preparation may shrink its pessimistic credit only after its temporary
  /// bodies have left the worker. Accepted payload and finish credit stay owned
  /// by the FIFO until commit, rollback-attested refusal, or receipt recovery.
  func resizeCharge(_ charge: UUID, to cost: Cost) throws {
    guard let allocation = allocations[charge], allocation.accepted,
      cost.bytes <= allocation.cost.bytes else { throw capacityFailure() }
    occupiedBytes -= allocation.cost.bytes - cost.bytes
    acceptedPayloadBytes += cost.payloadBytes - allocation.cost.payloadBytes
    acceptedCompletionBytes += cost.completionBytes - allocation.cost.completionBytes
    allocations[charge] = .init(cost: cost, accepted: true)
  }

  private func capacityFailure() -> NotebookPersistenceQueue.Failure {
    .init(message: "Работа превышает зарезервированную ёмкость сохранения.")
  }

  func release(_ reservation: Reservation) {
    guard reservation.owner == id, allocations[reservation.id]?.accepted == false else { return }
    releaseCharge(reservation.id)
  }

  func releaseCharge(_ charge: UUID) {
    guard let allocation = allocations.removeValue(forKey: charge) else { return }
    occupiedBytes -= allocation.cost.bytes
    if allocation.accepted {
      acceptedPayloadBytes -= allocation.cost.payloadBytes
      acceptedCompletionBytes -= allocation.cost.completionBytes
    }
  }
}
