import Foundation

public enum PresencePhase: String, Codable, Equatable, Sendable {
  case active
  case settled
}

/// Orders the transient camera frames of one app run and distinguishes the
/// durable final scene from motion that happened to be in flight.
public struct PresenceEnvelope: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let sequence: UInt64
  public let phase: PresencePhase
  public let presence: SessionPresence

  public init(
    sessionID: UUID,
    sequence: UInt64,
    phase: PresencePhase,
    presence: SessionPresence
  ) {
    self.sessionID = sessionID
    self.sequence = sequence
    self.phase = phase
    self.presence = presence
  }

  public var isValid: Bool {
    sequence <= VersionStamp.maximumCounter && presence.isValid
      && (phase == .active || presence.isSettled)
  }
}

/// A Mac interaction asks the iPad, which owns session presence, to select one
/// physical document sheet. The iPad publishes the resulting authoritative
/// presence; this request never becomes a second persistent page owner.
public struct DocumentPageSelectionRequest: Codable, Equatable, Sendable {
  public static let maximumPageIndex = 100_000

  public let documentID: UUID
  public let pageIndex: Int

  public init(documentID: UUID, pageIndex: Int) {
    self.documentID = documentID
    self.pageIndex = pageIndex
  }

  public var isValid: Bool {
    pageIndex >= 0 && pageIndex <= Self.maximumPageIndex
  }
}

public enum WireMessage: Codable, Equatable, Sendable {
  case index(WorkspaceIndex)
  case page(PageDocument)
  case drawing(
    pageID: UUID,
    data: Data,
    stamp: VersionStamp
  )
  case elements(
    pageID: UUID,
    elements: [AgentElement],
    stamp: VersionStamp,
    collaboration: CollaborativeContent?
  )
  case document(DocumentDocument)
  case documentState(DocumentStateJournal)
  case board(BoardHierarchy)
  case spatialInk(SpatialInkJournal)
  case presence(PresenceEnvelope)
  case documentPageSelection(DocumentPageSelectionRequest)
}
