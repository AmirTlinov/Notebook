import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
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
    agentRasters: RasterBatchLease,
    documentRaster: RasterLease?,
    pngURL: URL,
    receiptURL: URL
  ) async throws {
    guard let activeBoard = board.board(presence.boardID) else {
      throw PreviewError.invalidSurface
    }
    let snapshot = try await makeSnapshot(
      presence: presence,
      spatialElements: WorkspaceSceneProjection.snapshotLayers(
        workspace: workspace, hierarchy: board, presence: presence, documents: model.documents
      ).elements,
      page: page,
      document: document,
      documentState: documentState,
      agentRasters: agentRasters,
      documentRaster: documentRaster
    )
    let content = SettledCurrentView(
      snapshot: snapshot,
      workspace: workspace,
      board: activeBoard,
      spatialInk: spatialInk,
      presence: presence
    )
    .environment(model)
    .environment(\.sceneSnapshotRasters, agentRasters)
    .frame(width: viewport.width, height: viewport.height)
    let png = try await renderPNG(
      content,
      size: viewport,
      scale: 2,
      inkSurfaces: [.board, .cover].contains(presence.mode)
        ? WorkspaceSceneProjection.snapshotLayers(workspace: workspace, hierarchy: board, presence: presence, documents: model.documents).ink : [],
      journal: spatialInk
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
    try Task.checkCancellation()
    guard model.permitsBackgroundPreparation, model.presence == presence,
      model.presencePhase == .settled, model.workspace == workspace,
      model.boardHierarchy?.revision == board.revision, model.spatialInk?.stamp == spatialInk.stamp,
      page == nil || model.pages[page!.id] == page,
      document == nil || model.documents[document!.id] == document,
      documentState == nil || model.documentStates[documentState!.id] == documentState
    else { throw PreviewError.sourceChanged }
    try await Task.detached(priority: .utility) {
      try FileManager.default.createDirectory(at: pngURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try png.write(to: pngURL, options: [.atomic])
      try receiptData.write(to: receiptURL, options: [.atomic])
    }.value
  }

  @MainActor
  static func writeTarget(_ request: TargetRenderRequest, model: NotebookAppModel) async throws {
    guard let content = model.collaborationContent else { throw PreviewError.sourceChanged }
    let files = try await Task.detached(priority: .utility) { try content.sourceFiles() }.value
    guard try await Task.detached(priority: .utility, operation: {
      try NotebookStore.referenceRevision(target: request.target, files: files)
    }).value == request.sourceRevision else { throw PreviewError.sourceChanged }
    let target = request.target
    let full: RasterSnapshot
    var camera: SpatialCamera?
    var diagnostics: [RenderDiagnostic] = []
    var inkRegions: [PageRect] = []
    var inkRaster: RasterSnapshot?
    var documentRaster: RasterLease?
    defer { documentRaster?.release() }
    switch target.kind {
    case .page:
      guard let page = model.pages[target.id] else { throw PreviewError.invalidSurface }
      let resources = try await SceneRenderResources.shared.prepare(page.elements)
      defer { resources.release() }
      full = try await pageCompositeSnapshot(page, rasters: resources)
      inkRegions = try await Task.detached(priority: .utility) { try PageVisionRenderer.render(page).regions.map { $0.receipt.contentPoints } }.value
      await PageInkRasterCache.shared.prepare(page)
      guard let ink = PageInkRasterCache.shared.image(for: page) else { throw PreviewError.agentSnapshotPending }
      inkRaster = try await raster(NSImage(cgImage: ink, size: .init(width: page.size.width, height: page.size.height)))
      diagnostics = SceneRenderResources.shared.diagnostics(for: page.elements)
    case .document:
      guard let document = model.documents[target.id], let state = model.documentStates[target.id] else { throw PreviewError.invalidSurface }
      let preparedDocument = try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: request.pageIndex)
      documentRaster = preparedDocument
      full = try await raster(preparedDocument.image)
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
      let elements = WorkspaceSceneProjection.snapshotLayers(workspace: content.workspace, hierarchy: content.hierarchy,
        presence: presence, documents: model.documents).elements.filter { $0.kind != .nativeText }.map(agentElementSnapshotSource)
      let resources = try await SceneRenderResources.shared.prepare(elements)
      defer { resources.release() }
      let view = SettledSpatialWorkspaceView(workspace: content.workspace, board: board, spatialInk: content.ink, presence: presence)
        .environment(model).environment(\.sceneSnapshotRasters, resources)
        .frame(width: size.width, height: size.height)
      let png = try await renderPNG(view, size: size, scale: 2,
        inkSurfaces: WorkspaceSceneProjection.snapshotLayers(workspace: content.workspace, hierarchy: content.hierarchy,
          presence: presence, documents: model.documents).ink, journal: content.ink)
      guard let image = NSImage(data: png) else { throw PreviewError.pngEncoding }
      full = RasterSnapshot(image: image, png: png)
      diagnostics = SceneRenderResources.shared.diagnostics(for: elements)
      let inkSurface = WorkspaceSceneProjection.SnapshotInkSurface(surface: target.kind == .cover ? .cover(target.id) : .board(target.id),
        camera: target.kind == .board ? projection : nil, viewport: .init(x: size.width, y: size.height))
      let inkSnapshot = try await SpatialInkRasterSnapshot.prepare([inkSurface], journal: content.ink)
      if let inkImage = inkSnapshot.raster(for: inkSurface) {
        inkRegions = await Task.detached(priority: .utility) { SpatialInkRasterSnapshot.occupiedRegions(inkImage, size: size) }.value
        inkRaster = try await raster(NSImage(cgImage: inkImage, size: size))
      }
    case .workspace: throw PreviewError.invalidSurface
    }
    try Task.checkCancellation()
    guard model.permitsBackgroundPreparation else { throw PreviewError.inputActive }
    let output = target.kind == .board ? full : try crop(full, region: request.region)
    let ink = try inkRaster.map { target.kind == .board ? $0 : try crop($0, region: request.region) }
    let inkFingerprint = ink?.sha256 ?? "empty-ink"
    let png = output.png, outputHash = output.sha256, store = model.store
    let outputCamera = camera, outputDiagnostics = diagnostics, outputRegions = inkRegions
    try await Task.detached(priority: .utility) {
      guard try store.referenceRevision(target: target) == request.sourceRevision else { throw PreviewError.sourceChanged }
      guard let image = NSBitmapImageRep(data: png) else { throw PreviewError.pngEncoding }
      let fingerprint = request.region == nil ? nil : target.kind == .document ? outputHash
        : try NotebookStore.regionalFingerprint(request, inkFingerprint: inkFingerprint, files: files)
      try store.saveTargetRender(.init(request: request, status: "ready", pngSHA256: outputHash, referenceFingerprint: fingerprint,
        pixelSize: .init(x: Double(image.pixelsWide), y: Double(image.pixelsHigh)), camera: outputCamera,
        diagnostics: outputDiagnostics, inkRegions: outputRegions), png: png)
    }.value
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
    documentState: DocumentStateJournal?,
    agentRasters: RasterBatchLease,
    documentRaster: RasterLease?
  ) async throws -> SettledSceneSnapshot {
    switch presence.mode {
    case .board:
      try requireSpatialElementSnapshots(spatialElements, rasters: agentRasters)
      return .board(boardID: presence.boardID)
    case .cover:
      guard let itemID = presence.focusedItemID else {
        throw PreviewError.invalidSurface
      }
      try requireSpatialElementSnapshots(spatialElements, rasters: agentRasters)
      return .cover(itemID: itemID)
    case .page:
      guard let page, let itemID = presence.focusedItemID else {
        throw PreviewError.invalidSurface
      }
      return .page(
        try await pageCompositeSnapshot(page, rasters: agentRasters),
        itemID: itemID,
        CurrentViewPageRevision(page: page)
      )
    case .document:
      guard let document, let documentState,
        let image = documentRaster?.image(for: .document(id: document.id,
          token: DocumentSnapshotCache.token(document: document, state: documentState,
            pageIndex: presence.documentPageIndex)))
      else { throw PreviewError.documentSnapshotPending }
      return .document(
        try await raster(image),
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
    _ page: PageDocument,
    rasters: RasterBatchLease
  ) async throws -> RasterSnapshot {
    let faithfulPNG = try await Task.detached(priority: .utility) { try PageVisionRenderer.faithfulPNG(page) }.value
    try Task.checkCancellation()
    guard let base = NSImage(data: faithfulPNG) else {
      throw PreviewError.pngEncoding
    }
    guard !page.elements.isEmpty else {
      return RasterSnapshot(image: base, png: faithfulPNG)
    }
    let overlays = try page.elements.map { element in
      guard let image = rasters.image(for: element, minimumScale: 2) else {
        throw PreviewError.agentSnapshotPending
      }
      return (element: element, image: image)
    }
    let size = CGSize(width: page.size.width, height: page.size.height)
    let png = try await renderPNG(
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
    _ elements: [SpatialElement],
    rasters: RasterBatchLease
  ) throws {
    for element in elements where element.kind != .nativeText {
      guard rasters.image(
        for: agentElementSnapshotSource(element), minimumScale: 2
      ) != nil else {
        throw PreviewError.agentSnapshotPending
      }
    }
  }

  @MainActor
  private static func raster(_ image: NSImage) async throws -> RasterSnapshot {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PreviewError.pngEncoding }
    let scale = Double(cgImage.width) / max(1, image.size.width)
    let png = try await Task.detached(priority: .utility) { try encodePNG(cgImage, scale: scale) }.value
    return RasterSnapshot(image: image, png: png)
  }

  private static func encodePNG(_ image: CGImage, scale: Double) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw PreviewError.pngEncoding }
    CGImageDestinationAddImage(destination, image,
      [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw PreviewError.pngEncoding }
    return data as Data
  }

  @MainActor
  private static func renderPNG<Content: View>(
    _ content: Content,
    size: CGSize,
    scale: CGFloat,
    inkSurfaces: [WorkspaceSceneProjection.SnapshotInkSurface] = [],
    journal: SpatialInkJournal? = nil
  ) async throws -> Data {
    let prepared = try await SpatialInkRasterSnapshot.prepare(inkSurfaces, journal: journal)
    let renderer = ImageRenderer(content: content.environment(\.spatialInkRasterSnapshot, prepared))
    renderer.proposedSize = ProposedViewSize(size)
    renderer.scale = scale
    guard let image = renderer.cgImage else { throw PreviewError.pngEncoding }
    return try await Task.detached(priority: .utility) { try encodePNG(image, scale: scale) }.value
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
