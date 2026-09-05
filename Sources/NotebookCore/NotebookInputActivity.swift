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
    guard FileManager.default.fileExists(atPath: inputActivityURL.path) else { return [] }
    return try JSONDecoder().decode([NotebookInputActivity].self, from: Data(contentsOf: inputActivityURL))
  }

  public func inputActivities() throws -> [NotebookInputActivity] {
    try prepare()
    return try withMutationLock { try readInputActivities() }
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
      try JSONEncoder().encode(activities).write(to: inputActivityURL, options: .atomic)
    }
  }

  /// Process startup and connection loss explicitly end a remote runtime, not
  /// a human stroke. Content and action receipts are never changed here.
  public func resetInputActivities(keeping deviceID: UUID? = nil) throws {
    try prepare()
    try withMutationLock {
      let remaining = try readInputActivities().filter { $0.deviceID == deviceID }
      try JSONEncoder().encode(remaining).write(to: inputActivityURL, options: .atomic)
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

  func requireIdleInput(for targets: [CollaborationTarget], files: [String: JSONValue]) throws {
    let activities = try readInputActivities().filter(\.isActive)
    guard !activities.isEmpty else { return }
    let index = try files["workspace.json"]?.decode(WorkspaceIndex.self)
    let hierarchy = try files["board.json"]?.decode(BoardHierarchy.self)
    func carrier(_ target: CollaborationTarget) -> UUID {
      target.kind == .page ? (index?.items.first { $0.pageIDs.contains(target.id) }?.id ?? target.id) : target.id
    }
    func boards(_ target: CollaborationTarget) -> Set<UUID> {
      var result = Set<UUID>()
      var next = target.kind == .board ? target.id : hierarchy?.ownerBoardID(of: carrier(target))
      while let id = next, result.insert(id).inserted { next = hierarchy?.ownerBoardID(of: id) }
      return result
    }
    for activity in activities {
      for target in targets {
        if activity.targets.contains(where: { held in
          held == target || carrier(held) == carrier(target)
            || (held.kind == .board && boards(target).contains(held.id))
            || (target.kind == .board && boards(held).contains(target.id))
        }) {
          throw CollaborationError("input_active", "Ход пока не сохранён: человек взаимодействует с этой поверхностью. Повторите тот же запрос после завершения касания; версии будут проверены заново.", target: target)
        }
      }
    }
  }
}
