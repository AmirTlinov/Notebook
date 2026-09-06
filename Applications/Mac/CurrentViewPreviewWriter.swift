import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import NotebookCore
import SwiftUI

private struct RasterSnapshot {
  let image: NSImage
  let png: Data
  var diagnostics: [RenderDiagnostic] = []

  var sha256: String {
    SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
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
    documentRaster: RasterLease?,
    pngURL: URL,
    receiptURL: URL
  ) async throws {
    guard board.board(presence.boardID) != nil,
      viewport.width == presence.viewport.x, viewport.height == presence.viewport.y else { throw PreviewError.invalidSurface }
    let png: Data
    let surface: CurrentViewSurfaceRevision
    switch presence.mode {
    case .board, .cover:
      let index = try await WorkspaceSceneIndex.prepare(workspace: workspace, hierarchy: board,
        documents: model.documents, reusing: model.sceneIndex)
      let result = try await SceneCompositionRenderer(index: index, hierarchy: board, journal: spatialInk,
        permitsPreparation: { model.permitsBackgroundPreparation }).render(presence: presence)
      png = result.png
      if presence.mode == .cover {
        guard let id = presence.focusedItemID else { throw PreviewError.invalidSurface }
        surface = .cover(itemID: id)
      } else { surface = .board(boardID: presence.boardID) }
    case .page:
      guard let page, let id = presence.focusedItemID else { throw PreviewError.invalidSurface }
      let snapshot = try await pageCompositeSnapshot(page, permitsPreparation: { model.permitsBackgroundPreparation })
      png = try await fittedPNG(snapshot.image, viewport: viewport)
      surface = .page(itemID: id, revision: .init(page: page), snapshotPNG_SHA256: snapshot.sha256)
    case .document:
      guard let document, let documentState,
        let image = documentRaster?.image(for: .document(id: document.id,
          token: DocumentSnapshotCache.token(document: document, state: documentState,
            pageIndex: presence.documentPageIndex))) else { throw PreviewError.documentSnapshotPending }
      let snapshot = try await raster(image)
      png = try await fittedPNG(image, viewport: viewport)
      surface = .document(revision: .init(document: document, state: documentState),
        pageIndex: presence.documentPageIndex, snapshotPNG_SHA256: snapshot.sha256)
    }

    let receipt = CurrentViewReceipt(
      workspace: workspace,
      board: board,
      spatialInk: spatialInk,
      presence: presence,
      renderViewport: SpatialPoint(x: viewport.width, y: viewport.height),
      surface: surface,
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
      full = try await pageCompositeSnapshot(page, permitsPreparation: { model.permitsBackgroundPreparation })
      inkRegions = try await Task.detached(priority: .utility) { try PageVisionRenderer.render(page).regions.map { $0.receipt.contentPoints } }.value
      await PageInkRasterCache.shared.prepare(page)
      guard let ink = PageInkRasterCache.shared.image(for: page) else { throw PreviewError.agentSnapshotPending }
      inkRaster = try await raster(NSImage(cgImage: ink, size: .init(width: page.size.width, height: page.size.height)))
      diagnostics = full.diagnostics
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
      let index = try await WorkspaceSceneIndex.prepare(workspace: content.workspace, hierarchy: content.hierarchy,
        documents: model.documents, reusing: model.sceneIndex)
      let result = try await SceneCompositionRenderer(index: index, hierarchy: content.hierarchy, journal: content.ink,
        permitsPreparation: { model.permitsBackgroundPreparation }).render(presence: presence)
      guard let image = NSImage(data: result.png) else { throw PreviewError.pngEncoding }
      full = RasterSnapshot(image: image, png: result.png)
      diagnostics = result.diagnostics
      if let ink = try await SpatialInkRasterSnapshot.prepare(
        surface: target.kind == .cover ? .cover(target.id) : .board(target.id),
        camera: target.kind == .board ? projection : nil, size: size, journal: content.ink,
        permitsPreparation: { model.permitsBackgroundPreparation }) {
        guard let image = NSImage(data: ink.png) else { throw PreviewError.pngEncoding }
        inkRegions = ink.regions
        inkRaster = RasterSnapshot(image: image, png: ink.png)
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
  private static func pageCompositeSnapshot(
    _ page: PageDocument,
    permitsPreparation: @escaping @MainActor () -> Bool
  ) async throws -> RasterSnapshot {
    let size = CGSize(width: page.size.width, height: page.size.height)
    let resources = SceneRenderResources.shared
    let compositor = try await SceneRasterCompositor.create(size: size,
      scale: PageVisionRenderer.scale, resources: resources, permitsPreparation: permitsPreparation)
    let faithfulPNG = try await Task.detached(priority: .utility) { try PageVisionRenderer.faithfulPNG(page) }.value
    try await compositor.drawPNG(faithfulPNG, in: CGRect(origin: .zero, size: size))
    for element in page.elements {
      try Task.checkCancellation()
      let raster = try await resources.prepareRaster(element, permitsPreparation: permitsPreparation)
      do {
        try await compositor.draw(raster, in: CGRect(x: element.frame.x, y: element.frame.y,
          width: element.frame.width, height: element.frame.height))
        raster.release()
      } catch { raster.release(); throw error }
      compositor.recordDiagnostics(resources.diagnostics(for: [element]))
    }
    let png = try await compositor.finishPNG()
    guard let image = NSImage(data: png) else { throw PreviewError.pngEncoding }
    return RasterSnapshot(image: image, png: png, diagnostics: compositor.diagnostics)
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
  private static func fittedPNG(_ image: NSImage, viewport: CGSize) async throws -> Data {
    let content = Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
      .frame(width: viewport.width, height: viewport.height)
      .background(Color(red: 0.992, green: 0.988, blue: 0.969))
    let renderer = ImageRenderer(content: content)
    renderer.proposedSize = ProposedViewSize(viewport)
    renderer.scale = 2
    guard let image = renderer.cgImage else { throw PreviewError.pngEncoding }
    return try await Task.detached(priority: .utility) { try encodePNG(image, scale: 2) }.value
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
