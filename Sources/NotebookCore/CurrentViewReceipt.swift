import Foundation

public struct CurrentViewPageRevision: Codable, Equatable, Sendable {
  public let pageID: UUID
  public let drawingStamp: VersionStamp
  public let agentStamp: VersionStamp

  public init(page: PageDocument) {
    pageID = page.id
    drawingStamp = page.drawingStamp
    agentStamp = page.agentStamp
  }
}

public struct CurrentViewDocumentRevision: Codable, Equatable, Sendable {
  public let documentID: UUID
  public let contentStamp: VersionStamp
  public let stateStamp: VersionStamp

  public init(
    document: DocumentDocument,
    state: DocumentStateJournal
  ) {
    precondition(document.id == state.id)
    documentID = document.id
    contentStamp = document.contentStamp
    stateStamp = state.stamp
  }
}

/// Exact source versions used to render `previews/current-view.png`.
public struct CurrentViewReceipt: Codable, Equatable, Sendable {
  public static let formatVersion = 2

  public let format: Int
  public let workspaceStamp: VersionStamp
  public let boardStamp: VersionStamp
  public let spatialInkStamp: VersionStamp
  public let presence: SessionPresence
  public let renderViewport: SpatialPoint
  public let page: CurrentViewPageRevision?
  public let document: CurrentViewDocumentRevision?
  public let pngSHA256: String

  public init(
    workspace: WorkspaceIndex,
    board: BoardDocument,
    spatialInk: SpatialInkJournal,
    presence: SessionPresence,
    renderViewport: SpatialPoint,
    page: PageDocument?,
    document: DocumentDocument?,
    documentState: DocumentStateJournal?,
    pngSHA256: String
  ) {
    precondition(renderViewport.x > 0 && renderViewport.y > 0)
    precondition((document == nil) == (documentState == nil))
    format = Self.formatVersion
    workspaceStamp = workspace.stamp
    boardStamp = board.stamp
    spatialInkStamp = spatialInk.stamp
    self.presence = presence
    self.renderViewport = renderViewport
    self.page = page.map(CurrentViewPageRevision.init)
    self.document = document.map {
      CurrentViewDocumentRevision(document: $0, state: documentState!)
    }
    self.pngSHA256 = pngSHA256
  }

  public var isValid: Bool {
    format == Self.formatVersion && presence.isValid
      && renderViewport.isValid
      && renderViewport.x > 0 && renderViewport.y > 0
      && (presence.mode != .page || page != nil)
      && (presence.mode != .document || document != nil)
      && !(page != nil && document != nil)
      && pngSHA256.count == 64
      && pngSHA256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }
}
