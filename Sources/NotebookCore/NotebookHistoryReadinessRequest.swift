import Foundation

/// A reversible native coordination request. It grants no format activation.
public struct NotebookHistoryReadinessRequest: Codable, Equatable, Sendable {
  public enum Operation: String, Codable, Sendable { case start, status, cancel }
  public let operation: Operation
  public let requestID: UUID
  public let deviceIDs: [UUID]?

  public init(operation: Operation, requestID: UUID, deviceIDs: [UUID]? = nil) {
    self.operation = operation; self.requestID = requestID; self.deviceIDs = deviceIDs
  }

  public func validate() throws {
    if operation == .start {
      guard let deviceIDs, deviceIDs.count == 2, Set(deviceIDs).count == 2 else {
        throw CollaborationError("invalid_history_fleet", "Укажите два устройства, содержащие историю пространства.")
      }
    } else if deviceIDs != nil {
      throw CollaborationError("invalid_history_request", "Состояние и отмена используют только исходный requestID.")
    }
  }
}
