import Foundation

public struct RequestGrant: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, Sendable { case question, change }
  public let id: UUID
  public let mode: Mode
  public let references: [CollaborationReference]

  public init(id: UUID = UUID(), mode: Mode, references: [CollaborationReference]) throws {
    self.id = id; self.mode = mode; self.references = references
    try validate()
  }

  public func validate() throws {
    guard (1...32).contains(references.count), Set(references.map(\.id)).count == references.count else {
      throw CollaborationError("invalid_grant", "Разрешение называет от 1 до 32 закреплённых фрагментов.")
    }
    for reference in references {
      guard reference.target.kind != .workspace,
        reference.target.kind != .cover || reference.target.boardID != nil,
        reference.revision.utf8.count <= 256, !reference.revision.isEmpty,
        (reference.elementID?.utf8.count ?? 0) <= 512,
        (reference.pageIndex ?? 0) >= 0,
        reference.worldOrigin?.isValid != false,
        reference.region.map({ $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite
          && $0.width > 0 && $0.height > 0 }) != false else {
        throw CollaborationError("invalid_grant", "Разрешение содержит конечные области физических владельцев.")
      }
    }
  }

  /// Membership is exact: a selected portal does not grant its descendants,
  /// and a cover does not grant notebook pages or a document's hidden source.
  public func references(to target: CollaborationTarget) -> [CollaborationReference] {
    references.filter { $0.target == target }
  }

  public func permits(target: CollaborationTarget, elementID: String?, region: PageRect?,
    worldOrigin: WorldPoint? = nil) -> Bool {
    references(to: target).contains { reference in
      if let selected = reference.elementID, selected != elementID { return false }
      guard let allowed = reference.region else { return true }
      guard let region, region.x.isFinite, region.y.isFinite, region.width.isFinite,
        region.height.isFinite, region.width >= 0, region.height >= 0 else { return false }
      let delta = (reference.worldOrigin ?? .zero).delta(to: worldOrigin ?? .zero)
      return delta.x.isFinite && delta.y.isFinite
        && region.x + delta.x >= allowed.x && region.y + delta.y >= allowed.y
        && region.x + delta.x + region.width <= allowed.x + allowed.width
        && region.y + delta.y + region.height <= allowed.y + allowed.height
    }
  }
}

/// Historical archive schema only. There is no Notebook executor or permission
/// authority behind these records; new conversations belong to Codex.
public struct AgentRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let contextID: UUID
  public let questionEntryID: UUID
  public let grant: RequestGrant
  public let createdAt: Date
  public let authorDeviceID: UUID
  public let sourceIDs: [UUID]

  public init(id: UUID = UUID(), contextID: UUID, questionEntryID: UUID, grant: RequestGrant,
    createdAt: Date = Date(), authorDeviceID: UUID, sourceIDs: [UUID]) {
    self.id = id; self.contextID = contextID; self.questionEntryID = questionEntryID
    self.grant = grant; self.createdAt = createdAt; self.authorDeviceID = authorDeviceID
    self.sourceIDs = sourceIDs
  }
}

public struct AgentExecution: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case running, completed, stopped, failed }
  public let requestID: UUID
  public let executionID: UUID
  public var status: Status
  public var stamp: VersionStamp
  public var responseSequence: UInt64
  public var responseBytes: Int
  public var receiptIDs: [UUID]
  public var answerEntryID: UUID?
  public var observedReferences: [UUID: String] = [:]
  public var error: String?
}

public struct AgentResponseChunk: Codable, Equatable, Sendable {
  public let requestID: UUID
  public let executionID: UUID
  public let sequence: UInt64
  public let text: String
}

public struct AgentStopIntent: Codable, Equatable, Sendable {
  public let requestID: UUID
  public let authorDeviceID: UUID
}

public struct AgentRequestSnapshot: Codable, Equatable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable { case queued, running, stopping, completed, stopped, failed }
  public let request: AgentRequest
  public let execution: AgentExecution?
  public let stopRequested: Bool
  public let responseText: String
  public var id: UUID { request.id }
  public var status: Status {
    if let execution {
      switch execution.status {
      case .completed: return .completed
      case .stopped: return .stopped
      case .failed: return .failed
      case .running: return stopRequested ? .stopping : .running
      }
    }
    return stopRequested ? .stopping : .queued
  }
}

extension AgentRequest {
  public func validate() throws {
    try grant.validate()
    guard createdAt.timeIntervalSince1970.isFinite, sourceIDs.count == grant.references.count,
      Set(sourceIDs) == Set(grant.references.map(\.id)) else {
      throw CollaborationError("invalid_request", "Запрос называет собственные закреплённые исходники.")
    }
  }
}
extension AgentExecution {
  public func validate() throws {
    guard stamp.counter <= VersionStamp.maximumCounter, responseSequence <= 2_048,
      (0...1_048_576).contains(responseBytes), receiptIDs.count <= 128,
      Set(receiptIDs).count == receiptIDs.count, observedReferences.count <= 32,
      observedReferences.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }), (error?.utf8.count ?? 0) <= 8_192,
      status == .completed || answerEntryID == nil else {
      throw CollaborationError("invalid_execution", "Состояние исполнения содержит недопустимую версию или объём.")
    }
  }
}
extension AgentResponseChunk {
  public func validate() throws {
    guard (1...2_048).contains(sequence), !text.isEmpty, text.utf8.count <= 8_192 else {
      throw CollaborationError("invalid_response_chunk", "Порция ответа имеет ограниченный номер и размер.")
    }
  }
}
