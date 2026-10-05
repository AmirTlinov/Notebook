import Foundation

/// Readers share priority and measurements with their print producer. Export
/// completion remains protected even when a visible reader promotes that job.
public final class NotebookTypesetterDemand: @unchecked Sendable {
  private let lock = NSLock()
  private var priority: NotebookTypesetter.Priority
  private var exportReader: Bool
  private weak var shared: NotebookTypesetterDemand?
  private var observers: [UUID: @Sendable () -> Void] = [:]
  private var phasesMS: [String: Double] = [:]
  private var sharesMeasurement = false
  public init(priority: NotebookTypesetter.Priority) { self.priority = priority; exportReader = priority == .export }
  var current: NotebookTypesetter.Priority { lock.lock(); defer { lock.unlock() }; return priority }
  var mayYield: Bool { lock.lock(); defer { lock.unlock() }; return priority != .current && !exportReader }
  public var preparationPhasesMS: [String: Double] {
    lock.lock(); let local = phasesMS, producer = sharesMeasurement ? shared : nil; lock.unlock()
    return (producer?.preparationPhasesMS ?? [:]).merging(local) { _, reader in reader }
  }
  func beginMeasurement() { lock.lock(); phasesMS = [:]; sharesMeasurement = false; lock.unlock() }
  func finishMeasurement() {
    let measured = preparationPhasesMS
    lock.lock(); phasesMS = measured; sharesMeasurement = false; lock.unlock()
  }
  func record(_ phase: String, since start: ContinuousClock.Instant, accumulating: Bool = false) {
    let elapsed = start.duration(to: .now).components
    record(phase, milliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15, accumulating: accumulating)
  }
  func record(_ phase: String, milliseconds: Double, accumulating: Bool = false) {
    lock.lock(); phasesMS[phase] = (accumulating ? phasesMS[phase, default: 0] : 0) + milliseconds; lock.unlock()
  }
  public func promote(to value: NotebookTypesetter.Priority) { promote(to: value, protectingExport: value == .export) }
  private func promote(to value: NotebookTypesetter.Priority, protectingExport: Bool) {
    lock.lock()
    let changed = value.rawValue < priority.rawValue || (protectingExport && !exportReader)
    if value.rawValue < priority.rawValue { priority = value }
    exportReader = exportReader || protectingExport
    let shared = shared, callbacks = changed ? Array(observers.values) : []
    lock.unlock()
    shared?.promote(to: value, protectingExport: protectingExport)
    callbacks.forEach { $0() }
  }
  func beginJob() { lock.lock(); shared = nil; sharesMeasurement = false; lock.unlock() }
  func join(_ producer: NotebookTypesetterDemand) {
    guard producer !== self else { return }
    lock.lock(); shared = producer; sharesMeasurement = true
    let priority = priority, exportReader = exportReader
    lock.unlock()
    producer.promote(to: priority, protectingExport: exportReader)
  }
  func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
    let id = UUID(); lock.lock(); observers[id] = callback; lock.unlock(); return id
  }
  func removeObserver(_ id: UUID) { lock.lock(); observers[id] = nil; lock.unlock() }
}
