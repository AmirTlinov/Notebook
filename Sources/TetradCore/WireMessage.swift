import Foundation

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
    stamp: VersionStamp
  )
  case board(BoardDocument)
  case spatialInk(SpatialInkJournal)
  case presence(SessionPresence)
}
