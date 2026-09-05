import AppKit
import CryptoKit
import NotebookCore
import SwiftUI

private struct RasterSnapshot {
  let image: NSImage
  let png: Data

  var sha256: String {
    SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
  }
}

private enum SettledSceneSnapshot {
  case board(boardID: UUID)
  case cover(itemID: UUID)
  case page(RasterSnapshot, itemID: UUID, CurrentViewPageRevision)
  case document(
    RasterSnapshot,
    CurrentViewDocumentRevision,
    pageIndex: Int
  )

  var receipt: CurrentViewSurfaceRevision {
    switch self {
    case .board(let boardID):
      return .board(boardID: boardID)
    case .cover(let itemID):
      return .cover(itemID: itemID)
    case .page(let snapshot, let itemID, let revision):
      return .page(
        itemID: itemID,
        revision: revision,
        snapshotPNG_SHA256: snapshot.sha256
      )
    case .document(let snapshot, let revision, let pageIndex):
      return .document(
        revision: revision,
        pageIndex: pageIndex,
        snapshotPNG_SHA256: snapshot.sha256
      )
    }
  }
}

private struct SettledCurrentView: View {
  let snapshot: SettledSceneSnapshot
  let workspace: WorkspaceIndex
  let board: BoardDocument
  let spatialInk: SpatialInkJournal
  let presence: SessionPresence

  @ViewBuilder
  var body: some View {
    switch snapshot {
    case .board, .cover:
      SettledSpatialWorkspaceView(
        workspace: workspace,
        board: board,
        spatialInk: spatialInk,
        presence: presence
      )
    case .page(let raster, _, _), .document(let raster, _, _):
      Image(nsImage: raster.image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.992, green: 0.988, blue: 0.969))
    }
  }
}

private struct PageCompositeSnapshotView: View {
  let base: NSImage
  let overlays: [(element: AgentElement, image: NSImage)]

  var body: some View {
    ZStack(alignment: .topLeading) {
      Image(nsImage: base)
        .resizable()
      ForEach(Array(overlays.enumerated()), id: \.offset) { _, overlay in
        Image(nsImage: overlay.image)
          .resizable()
          .frame(
            width: overlay.element.frame.width,
            height: overlay.element.frame.height
          )
          .offset(
            x: overlay.element.frame.x,
            y: overlay.element.frame.y
          )
      }
    }
  }
}

enum CurrentViewPreviewWriter {
  @MainActor
  static func write(
    model: NotebookAppModel,
    viewport: CGSize,
    workspace: WorkspaceIndex,
    board: BoardHierarchy,
    spatialInk: SpatialInkJournal,
    presence: SessionPresence,
    page: PageDocument?,
    document: DocumentDocument?,
    documentState: DocumentStateJournal?,
    pngURL: URL,
    receiptURL: URL
  ) throws {
    guard let activeBoard = board.board(presence.boardID) else {
      throw PreviewError.invalidSurface
    }
    let snapshot = try makeSnapshot(
      presence: presence,
      spatialElements: WorkspaceSceneProjection.snapshotElements(
        workspace: workspace, hierarchy: board, presence: presence, documents: model.documents
      ),
      page: page,
      document: document,
      documentState: documentState
    )
    let content = SettledCurrentView(
      snapshot: snapshot,
      workspace: workspace,
      board: activeBoard,
      spatialInk: spatialInk,
      presence: presence
    )
    .environment(model)
    .frame(width: viewport.width, height: viewport.height)
    let png = try renderPNG(
      content,
      size: viewport,
      scale: 2
    )

    let receipt = CurrentViewReceipt(
      workspace: workspace,
      board: board,
      spatialInk: spatialInk,
      presence: presence,
      renderViewport: SpatialPoint(x: viewport.width, y: viewport.height),
      surface: snapshot.receipt,
      pngSHA256: sha256(png)
    )
    guard receipt.isValid else { throw PreviewError.invalidReceipt }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let receiptData = try encoder.encode(receipt)
    try FileManager.default.createDirectory(
      at: pngURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try png.write(to: pngURL, options: [.atomic])
    try receiptData.write(to: receiptURL, options: [.atomic])
  }

  @MainActor
  static func writeTarget(_ request: TargetRenderRequest, model: NotebookAppModel) async throws {
    guard let content = model.collaborationContent,
      try NotebookStore.referenceRevision(target: request.target, files: content.sourceFiles()) == request.sourceRevision
    else { throw PreviewError.sourceChanged }
    let target = request.target
    let full: RasterSnapshot
    var camera: SpatialCamera?
    var diagnostics: [RenderDiagnostic] = []
    var inkRegions: [PageRect] = []
    switch target.kind {
    case .page:
      guard let page = model.pages[target.id] else { throw PreviewError.invalidSurface }
      try await AgentElementSnapshotCache.shared.prepare(page.elements)
      full = try pageCompositeSnapshot(page)
      inkRegions = try PageVisionRenderer.render(page).regions.map { $0.receipt.contentPoints }
      diagnostics = AgentElementSnapshotCache.shared.diagnostics(for: page.elements)
    case .document:
      guard let document = model.documents[target.id], let state = model.documentStates[target.id] else { throw PreviewError.invalidSurface }
      try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: request.pageIndex)
      guard let image = DocumentSnapshotCache.shared.image(for: document, state: state, pageIndex: request.pageIndex) else { throw PreviewError.documentSnapshotPending }
      full = try raster(image)
      diagnostics = DocumentRenderRegistry.shared.entry(document: document, state: state, pageIndex: request.pageIndex)?.diagnostics ?? []
    case .board, .cover:
      let boardID = target.kind == .board ? target.id : target.boardID!
      guard let board = content.hierarchy.board(boardID) else { throw PreviewError.invalidSurface }
      let size: CGSize
      let center: WorldPoint
      if target.kind == .cover {
        let geometry = model.itemGeometry(target.id)
        size = .init(width: geometry.width, height: geometry.height)
        guard let point = board.focusedCenter(of: target.id) else { throw PreviewError.invalidSurface }
        center = point
      } else {
        let region = request.region ?? PageRect(x: 0, y: 0, width: 1024, height: 768)
        size = .init(width: region.width, height: region.height)
        center = (request.worldOrigin ?? .zero).offsetBy(x: region.x + region.width / 2, y: region.y + region.height / 2)
      }
      let projection = SpatialCamera(center: center, scale: 1)
      camera = projection
      let presence = SessionPresence(boardID: boardID, mode: target.kind == .cover ? .cover : .board,
        camera: projection, viewport: .init(x: size.width, y: size.height), focusedItemID: target.kind == .cover ? target.id : nil)
      let elements = WorkspaceSceneProjection.snapshotElements(workspace: content.workspace, hierarchy: content.hierarchy,
        presence: presence, documents: model.documents).filter { $0.kind != .nativeText }.map(agentElementSnapshotSource)
      try await AgentElementSnapshotCache.shared.prepare(elements)
      let view = SettledSpatialWorkspaceView(workspace: content.workspace, board: board, spatialInk: content.ink, presence: presence)
        .environment(model).frame(width: size.width, height: size.height)
      let png = try renderPNG(view, size: size, scale: 2)
      guard let image = NSImage(data: png) else { throw PreviewError.pngEncoding }
      full = RasterSnapshot(image: image, png: png)
      diagnostics = AgentElementSnapshotCache.shared.diagnostics(for: elements)
      if let inkImage = SpatialInkRasterCache.shared.image(surface: target.kind == .cover ? .cover(target.id) : .board(target.id),
        journal: content.ink, camera: target.kind == .board ? projection : nil,
        viewport: presence.viewport, size: size) {
        inkRegions = SpatialInkRasterCache.shared.occupiedRegions(inkImage, size: size)
      }
    case .workspace: throw PreviewError.invalidSurface
    }
    try Task.checkCancellation()
    guard model.presencePhase == .settled else { throw PreviewError.inputActive }
    guard try model.store.referenceRevision(target: target) == request.sourceRevision else { throw PreviewError.sourceChanged }
    let output = target.kind == .board ? full : try crop(full, region: request.region)
    let image = NSBitmapImageRep(data: output.png)!
    try model.store.saveTargetRender(.init(request: request, status: "ready", pngSHA256: output.sha256,
      pixelSize: .init(x: Double(image.pixelsWide), y: Double(image.pixelsHigh)), camera: camera, diagnostics: diagnostics, inkRegions: inkRegions), png: output.png)
  }

  private static func crop(_ raster: RasterSnapshot, region: PageRect?) throws -> RasterSnapshot {
    guard let region else { return raster }
    guard let bitmap = NSBitmapImageRep(data: raster.png), let image = bitmap.cgImage else { throw PreviewError.pngEncoding }
    let scale = Double(image.width) / raster.image.size.width
    let rect = CGRect(x: region.x * scale, y: region.y * scale, width: region.width * scale, height: region.height * scale)
    guard rect.minX >= 0, rect.minY >= 0, rect.maxX <= Double(image.width), rect.maxY <= Double(image.height),
      let cropped = image.cropping(to: rect), let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    else { throw PreviewError.invalidSurface }
    return RasterSnapshot(image: NSImage(cgImage: cropped, size: .init(width: region.width, height: region.height)), png: png)
  }

  @MainActor
  private static func makeSnapshot(
    presence: SessionPresence,
    spatialElements: [SpatialElement],
    page: PageDocument?,
    document: DocumentDocument?,
    documentState: DocumentStateJournal?
  ) throws -> SettledSceneSnapshot {
    switch presence.mode {
    case .board:
      try requireSpatialElementSnapshots(spatialElements)
      return .board(boardID: presence.boardID)
    case .cover:
      guard let itemID = presence.focusedItemID else {
        throw PreviewError.invalidSurface
      }
      try requireSpatialElementSnapshots(spatialElements)
      return .cover(itemID: itemID)
    case .page:
      guard let page, let itemID = presence.focusedItemID else {
        throw PreviewError.invalidSurface
      }
      return .page(
        try pageCompositeSnapshot(page),
        itemID: itemID,
        CurrentViewPageRevision(page: page)
      )
    case .document:
      guard let document, let documentState,
        let image = DocumentSnapshotCache.shared.image(
          for: document,
          state: documentState,
          pageIndex: presence.documentPageIndex
        )
      else { throw PreviewError.documentSnapshotPending }
      return .document(
        try raster(image),
        CurrentViewDocumentRevision(
          document: document,
          state: documentState
        ),
        pageIndex: presence.documentPageIndex
      )
    }
  }

  @MainActor
  private static func pageCompositeSnapshot(
    _ page: PageDocument
  ) throws -> RasterSnapshot {
    let rendered = try PageVisionRenderer.render(page)
    guard let base = NSImage(data: rendered.faithfulPNG) else {
      throw PreviewError.pngEncoding
    }
    guard !page.elements.isEmpty else {
      return RasterSnapshot(image: base, png: rendered.faithfulPNG)
    }
    let overlays = try page.elements.map { element in
      guard let image = AgentElementSnapshotCache.shared.image(for: element) else {
        throw PreviewError.agentSnapshotPending
      }
      return (element: element, image: image)
    }
    let size = CGSize(width: page.size.width, height: page.size.height)
    let png = try renderPNG(
      PageCompositeSnapshotView(base: base, overlays: overlays),
      size: size,
      scale: CGFloat(PageVisionRenderer.scale)
    )
    guard let image = NSImage(data: png) else {
      throw PreviewError.pngEncoding
    }
    return RasterSnapshot(image: image, png: png)
  }

  @MainActor
  private static func requireSpatialElementSnapshots(
    _ elements: [SpatialElement]
  ) throws {
    for element in elements where element.kind != .nativeText {
      guard AgentElementSnapshotCache.shared.image(
        for: agentElementSnapshotSource(element)
      ) != nil else {
        throw PreviewError.agentSnapshotPending
      }
    }
  }

  private static func raster(_ image: NSImage) throws -> RasterSnapshot {
    guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { throw PreviewError.pngEncoding }
    return RasterSnapshot(image: image, png: png)
  }

  @MainActor
  private static func renderPNG<Content: View>(
    _ content: Content,
    size: CGSize,
    scale: CGFloat
  ) throws -> Data {
    let renderer = ImageRenderer(content: content)
    renderer.proposedSize = ProposedViewSize(size)
    renderer.scale = scale
    guard let image = renderer.nsImage,
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { throw PreviewError.pngEncoding }
    return png
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private enum PreviewError: Error {
    case agentSnapshotPending
    case documentSnapshotPending
    case invalidReceipt
    case invalidSurface
    case sourceChanged
    case inputActive
    case pngEncoding
  }
}
