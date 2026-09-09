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

  public init(document: DocumentDocument, state: DocumentStateJournal) {
    precondition(document.id == state.id)
    documentID = document.id
    contentStamp = document.contentStamp
    stateStamp = state.stamp
  }
}

/// The one settled surface whose pixels were used for `current-view.png`.
/// Page and document cases bind the scene to the exact raster dependency.
public enum CurrentViewSurfaceRevision: Equatable, Sendable {
  case board(boardID: UUID)
  case cover(itemID: UUID)
  case page(
    itemID: UUID,
    revision: CurrentViewPageRevision,
    snapshotPNG_SHA256: String
  )
  case document(
    revision: CurrentViewDocumentRevision,
    pageIndex: Int,
    snapshotPNG_SHA256: String
  )

  public var isValid: Bool {
    switch self {
    case .board, .cover:
      return true
    case .page(_, _, let hash):
      return Self.isSHA256(hash)
    case .document(_, let pageIndex, let hash):
      return pageIndex >= 0 && Self.isSHA256(hash)
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }
}

extension CurrentViewSurfaceRevision: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case itemID
    case boardID
    case revision
    case pageIndex
    case snapshotPNG_SHA256
  }

  private enum Kind: String, Codable {
    case board
    case cover
    case page
    case document
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .board:
      self = .board(
        boardID: try container.decode(UUID.self, forKey: .boardID)
      )
    case .cover:
      self = .cover(
        itemID: try container.decode(UUID.self, forKey: .itemID)
      )
    case .page:
      self = .page(
        itemID: try container.decode(UUID.self, forKey: .itemID),
        revision: try container.decode(
          CurrentViewPageRevision.self,
          forKey: .revision
        ),
        snapshotPNG_SHA256: try container.decode(
          String.self,
          forKey: .snapshotPNG_SHA256
        )
      )
    case .document:
      self = .document(
        revision: try container.decode(
          CurrentViewDocumentRevision.self,
          forKey: .revision
        ),
        pageIndex: try container.decode(Int.self, forKey: .pageIndex),
        snapshotPNG_SHA256: try container.decode(
          String.self,
          forKey: .snapshotPNG_SHA256
        )
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .board(let boardID):
      try container.encode(Kind.board, forKey: .kind)
      try container.encode(boardID, forKey: .boardID)
    case .cover(let itemID):
      try container.encode(Kind.cover, forKey: .kind)
      try container.encode(itemID, forKey: .itemID)
    case .page(let itemID, let revision, let hash):
      try container.encode(Kind.page, forKey: .kind)
      try container.encode(itemID, forKey: .itemID)
      try container.encode(revision, forKey: .revision)
      try container.encode(hash, forKey: .snapshotPNG_SHA256)
    case .document(let revision, let pageIndex, let hash):
      try container.encode(Kind.document, forKey: .kind)
      try container.encode(revision, forKey: .revision)
      try container.encode(pageIndex, forKey: .pageIndex)
      try container.encode(hash, forKey: .snapshotPNG_SHA256)
    }
  }
}

/// Exact source versions and raster dependency used for
/// `previews/current-view.png`.
public struct CurrentViewReceipt: Codable, Equatable, Sendable {
  public static let formatVersion = 6

  public let format: Int
  public let workspaceStamp: VersionStamp
  public let boardRevision: String
  public let spatialInkStamp: VersionStamp
  public let presence: SessionPresence
  public let renderViewport: SpatialPoint
  public let surface: CurrentViewSurfaceRevision
  public let pngSHA256: String

  public init(
    workspace: WorkspaceIndex,
    board: BoardHierarchy,
    spatialInk: SpatialInkJournal,
    presence: SessionPresence,
    renderViewport: SpatialPoint,
    surface: CurrentViewSurfaceRevision,
    pngSHA256: String
  ) {
    self.init(workspaceStamp: workspace.stamp, boardRevision: board.revision,
      spatialInkStamp: spatialInk.stamp, presence: presence,
      renderViewport: renderViewport, surface: surface, pngSHA256: pngSHA256)
  }

  /// SQL readers supply the completed header's Merkle revision, never the
  /// revision of a bounded display projection of the board tree.
  public init(workspaceStamp: VersionStamp, boardRevision: String,
    spatialInkStamp: VersionStamp, presence: SessionPresence,
    renderViewport: SpatialPoint, surface: CurrentViewSurfaceRevision, pngSHA256: String) {
    precondition(renderViewport.x > 0 && renderViewport.y > 0)
    format = Self.formatVersion
    self.workspaceStamp = workspaceStamp
    self.boardRevision = boardRevision
    self.spatialInkStamp = spatialInkStamp
    self.presence = presence
    self.renderViewport = renderViewport
    self.surface = surface
    self.pngSHA256 = pngSHA256
  }

  public var isValid: Bool {
    format == Self.formatVersion && presence.isValid
      && boardRevision.count == 64
      && boardRevision.allSatisfy { $0.isHexDigit && !$0.isUppercase }
      && renderViewport.isValid
      && renderViewport.x > 0 && renderViewport.y > 0
      && surfaceMatchesPresence
      && surface.isValid
      && pngSHA256.count == 64
      && pngSHA256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  private var surfaceMatchesPresence: Bool {
    switch (presence.mode, surface) {
    case (.board, .board(let boardID)):
      return presence.boardID == boardID
    case (.cover, .cover(let itemID)):
      return presence.focusedItemID == itemID
    case (.page, .page(let itemID, _, _)):
      return presence.focusedItemID == itemID
    case (.document, .document(_, let pageIndex, _)):
      return presence.focusedItemID != nil
        && presence.documentPageIndex == pageIndex
    default:
      return false
    }
  }
}
