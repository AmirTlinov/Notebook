import Foundation

/// Transient contact belongs to a connected device, not to document history.
/// A disconnect removes its publication barrier; the receiving device still
/// holds an in-flight composition locally until its own contact has finished.
public struct NotebookInputActivity: Codable, Equatable, Sendable {
  public let deviceID: UUID
  public let sessionID: UUID
  public let sequence: UInt64
  public let targets: [CollaborationTarget]

  public init(deviceID: UUID, sessionID: UUID, sequence: UInt64, targets: [CollaborationTarget]) {
    self.deviceID = deviceID; self.sessionID = sessionID
    self.sequence = sequence; self.targets = targets
  }

  public var isActive: Bool { !targets.isEmpty }
  public var isValid: Bool { sequence <= VersionStamp.maximumCounter && targets.count <= 4 && Set(targets).count == targets.count }
}

extension NotebookStore {
  var runtimeURL: URL { root.appendingPathComponent("runtime", isDirectory: true) }
  private var inputActivityURL: URL { runtimeURL.appendingPathComponent("input.json") }

  private func readInputActivities() throws -> [NotebookInputActivity] {
    try storedValue("runtime/input.json")?.decode([NotebookInputActivity].self) ?? []
  }

  public func inputActivities() throws -> [NotebookInputActivity] {
    try prepare()
    return try readTransaction { _ in try readInputActivities() }
  }

  public func saveInputActivity(_ activity: NotebookInputActivity) throws {
    guard activity.isValid else { throw CollaborationError("invalid_input_activity", "Контакт называет до четырёх физических владельцев.") }
    try prepare()
    try withMutationLock {
      var activities = try readInputActivities()
      if let old = activities.first(where: { $0.deviceID == activity.deviceID }),
        old.sessionID == activity.sessionID, old.sequence >= activity.sequence { return }
      activities.removeAll { $0.deviceID == activity.deviceID }
      activities.append(activity)
      try publishRecords(writes: ["runtime/input.json": try .encode(activities)])
    }
  }

  /// Process startup and connection loss explicitly end a remote runtime, not
  /// a human stroke. Content and action receipts are never changed here.
  public func resetInputActivities(keeping deviceID: UUID? = nil) throws {
    try prepare()
    try withMutationLock {
      let remaining = try readInputActivities().filter { $0.deviceID == deviceID }
      try publishRecords(writes: ["runtime/input.json": try .encode(remaining)])
    }
  }

  /// The bridge and native background commands share bounded waiting. No
  /// content lock is held while asleep, and every retry revalidates the action.
  func waitingForInput<T>(_ seconds: TimeInterval, _ operation: () throws -> T) throws -> T {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(seconds.isFinite ? min(4, max(0, seconds)) : 0)
    while true {
      do { return try operation() }
      catch let error as CollaborationError where error.code == "input_active" {
        repeat {
          guard clock.now < deadline else { throw error }
          Thread.sleep(forTimeInterval: 0.05)
        } while try inputActivities().contains(where: \.isActive)
      }
    }
  }

  func requireIdleInput(for targets: [CollaborationTarget]) throws {
    let activities = try readInputActivities().filter(\.isActive)
    guard !activities.isEmpty else { return }
    var carriers: [CollaborationTarget: UUID] = [:], ancestors: [CollaborationTarget: Set<UUID>] = [:]
    func carrier(_ target: CollaborationTarget) throws -> UUID {
      if let cached = carriers[target] { return cached }
      let value = target.kind == .page ? try ownerItemID(ofPage: target.id) ?? target.id : target.id
      carriers[target] = value; return value
    }
    func boards(_ target: CollaborationTarget) throws -> Set<UUID> {
      if let cached = ancestors[target] { return cached }
      var result = Set<UUID>()
      var next = target.kind == .board ? target.id : try ownerBoardID(of: carrier(target))
      while let id = next {
        guard result.insert(id).inserted else { throw NotebookStorageError.corruptRecord("board cycle") }
        next = try ownerBoardID(of: id)
      }
      ancestors[target] = result; return result
    }
    for activity in activities {
      for target in targets {
        if try activity.targets.contains(where: { held in
          try held == target || carrier(held) == carrier(target)
            || (held.kind == .board && boards(target).contains(held.id))
            || (target.kind == .board && boards(held).contains(target.id))
        }) {
          throw CollaborationError("input_active", "Ход пока не сохранён: человек взаимодействует с этой поверхностью. Повторите тот же запрос после завершения касания; версии будут проверены заново.", target: target)
        }
      }
    }
  }
}

extension NotebookStore {
  public func resetInputActivity(deviceID: UUID) throws {
    try commandTransaction {
      let remaining = try readInputActivities().filter { $0.deviceID != deviceID }
      try publishRecords(writes: ["runtime/input.json": try .encode(remaining)])
    }
  }
}
