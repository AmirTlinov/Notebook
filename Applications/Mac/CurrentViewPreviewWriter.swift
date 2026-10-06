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

struct CurrentViewPublicationFiles: Sendable {
  let png: (data: Data, url: URL)?
  let receipt: Data
  let receiptURL: URL

  func write() throws {
    if let png {
      try FileManager.default.createDirectory(at: png.url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try png.data.write(to: png.url, options: .atomic)
    }
    try receipt.write(to: receiptURL, options: .atomic)
  }
}

enum CurrentViewPreviewWriter {
  /// Revalidate the already published pixels, then advance only their general
  /// workspace metadata. Script readers can keep their strict receipt fence
  /// without making an unrelated edit render the same image again.
  static func refreshReceipt(store: NotebookStore, presence: SessionPresence,
    identity: PreviewSourceIdentity, dependencies: ScenePixelDependencies?, permit: NotebookPreviewPublication<CurrentViewPublicationFiles?>) throws {
    try permit.publish(preparing: { try store.readTransaction { store in
      guard let receipt = try store.loadCurrentViewReceipt(),
        receipt.presence.previewPixelIdentity == presence.previewPixelIdentity else { return nil }
      let header = try store.workspaceHeader()
      guard receipt.workspaceStamp != header.stamp || receipt.boardRevision != header.boardRevision
        || receipt.spatialInkStamp != header.spatialInkStamp || receipt.presence != presence else { return nil }
      if let dependencies {
        guard try dependencies.isCurrent(store) else { throw PreviewError.sourceChanged }
      } else {
        guard try PreviewSourceIdentity.read(store, presence: presence) == identity else { throw PreviewError.sourceChanged }
      }
      guard let boardRevision = header.boardRevision, let inkStamp = header.spatialInkStamp else { throw PreviewError.invalidReceipt }
      let updated = CurrentViewReceipt(workspaceStamp: header.stamp, boardRevision: boardRevision,
        spatialInkStamp: inkStamp, presence: presence, renderViewport: receipt.renderViewport,
        surface: receipt.surface, pngSHA256: receipt.pngSHA256)
      guard updated.isValid else { throw PreviewError.invalidReceipt }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return .init(png: nil, receipt: try encoder.encode(updated), receiptURL: store.currentViewRevisionURL)
    } }, writing: { try $0?.write() })
  }

  @MainActor
  @discardableResult
  static func write(
    model: NotebookAppModel,
    viewport: CGSize,
    presence: SessionPresence,
    page: PageDocument?,
    document: DocumentDocument?,
    documentState: DocumentStateJournal?,
    documentRaster: RasterLease?,
    sourceIdentity: PreviewSourceIdentity? = nil,
    pngURL: URL,
    receiptURL: URL
  ) async throws -> ScenePixelDependencies? {
    guard viewport.width == presence.viewport.x, viewport.height == presence.viewport.y else { throw PreviewError.invalidSurface }
    let store = model.store
    let reader = Task.detached(priority: .utility) {
      try store.readTransaction { store in
        let header = try store.workspaceHeader()
        guard try store.readBoardNodeHeader(presence.boardID) != nil else { throw PreviewError.invalidSurface }
        if let page {
          let current = try store.readContentHeader(target: .init(kind: .page, id: page.id))
          guard current.contentStamp == page.agentStamp, current.inkStamp == page.drawingStamp,
            current.size == page.size else { throw PreviewError.sourceChanged }
        }
        if let document, let documentState {
          let current = try store.readContentHeader(target: .init(kind: .document, id: document.id))
          guard current.contentStamp == document.contentStamp, current.stateStamp == documentState.stamp else { throw PreviewError.sourceChanged }
        }
        let identity = try PreviewSourceIdentity.read(store, presence: presence)
        guard sourceIdentity == nil || sourceIdentity == identity else { throw PreviewError.sourceChanged }
        return (header, identity)
      }
    }
    let (header, identity) = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
    let identities: [NotebookReferenceIdentity]?
    if case .scene(let values) = identity { identities = values } else { identities = nil }
    let source = identities.map { SceneCompositionSource(store: store, revision: header.cursor, workspaceID: header.workspaceID,
      validationIdentities: $0, recordPixelDependencies: true, documentGeometry: model.documentPaperSizes) }
    let png: Data
    let surface: CurrentViewSurfaceRevision
    switch presence.mode {
    case .board, .cover:
      guard let source, try await source.boardExists(presence.boardID) else { throw PreviewError.invalidSurface }
      let result = try await SceneCompositionRenderer(source: source,
        permitsPreparation: { model.permitsBackgroundPreparation }).render(presence: presence)
      png = result.png
      if presence.mode == .cover {
        guard let id = presence.focusedItemID else { throw PreviewError.invalidSurface }
        surface = .cover(itemID: id)
      } else { surface = .board(boardID: presence.boardID) }
    case .page:
      guard let page, let id = presence.focusedItemID else { throw PreviewError.invalidSurface }
      let snapshot = try await pageCompositeSnapshot(page, programStore: model.store, permitsPreparation: { model.permitsBackgroundPreparation })
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

    let pngHash = sha256(png)
    let dependencies = try await source?.pixelDependencies()
    try Task.checkCancellation()
    guard model.permitsBackgroundPreparation, let currentPresence = model.observedPresence,
      currentPresence.previewPixelIdentity == presence.previewPixelIdentity,
      model.observedPresencePhase == .settled,
      model.workspaceHeader?.workspaceID == header.workspaceID
    else { throw PreviewError.sourceChanged }
    let permit = NotebookPreviewPublication<CurrentViewPublicationFiles?>()
    try await withTaskCancellationHandler {
      try await model.performStoreCommand { store in
        try permit.publish(preparing: { try store.readTransaction { store in
          let latest = try store.workspaceHeader()
          let current: Bool
          if let dependencies { current = try dependencies.isCurrent(store) }
          else { current = try PreviewSourceIdentity.read(store, presence: presence) == identity }
          guard latest.workspaceID == header.workspaceID, try store.readBoardNodeHeader(presence.boardID) != nil, current else { throw PreviewError.sourceChanged }
          guard let boardRevision = latest.boardRevision, let inkStamp = latest.spatialInkStamp else { throw PreviewError.invalidReceipt }
          let receipt = CurrentViewReceipt(workspaceStamp: latest.stamp, boardRevision: boardRevision,
            spatialInkStamp: inkStamp, presence: currentPresence,
            renderViewport: .init(x: viewport.width, y: viewport.height), surface: surface, pngSHA256: pngHash)
          guard receipt.isValid else { throw PreviewError.invalidReceipt }
          let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          return .init(png: (png, pngURL), receipt: try encoder.encode(receipt), receiptURL: receiptURL)
        } }, writing: { try $0?.write() })
      }
    } onCancel: { permit.revoke() }
    return dependencies
  }

  @MainActor
  static func writeTarget(_ request: TargetRenderRequest, model: NotebookAppModel) async throws {
    try request.requireCurrentRenderingRecipe()
    let store = model.store
    if let revision = request.pageVisionRevision {
      guard request.target.kind == .page, request.region == nil, request.worldOrigin == nil,
        request.pageIndex == 0 else { throw PreviewError.invalidSurface }
      guard model.permitsBackgroundPreparation else { throw PreviewError.inputActive }
      let worker = Task.detached(priority: .utility) {
        let page = try store.loadPage(request.target.id)
        guard page.drawingStamp.revision == revision,
          try NotebookStore.pageVisionSourceRevision(page) == request.sourceRevision else {
          throw PreviewError.sourceChanged
        }
        if !store.hasCurrentPageVision(page) {
          if !page.drawingData.isEmpty { try await InkRasterRenderer.shared.prepareInk() }
          try PagePreviewWriter.write(page, store: store)
        }
        try Task.checkCancellation()
        guard try NotebookStore.pageVisionSourceRevision(store.loadPage(page.id)) == request.sourceRevision,
          store.hasCurrentPageVision(page) else { throw PreviewError.sourceChanged }
        let vision = try JSONDecoder().decode(PageVisionReceipt.self,
          from: Data(contentsOf: store.previewVisionReceiptURL(page.id)))
        return TargetRenderReceipt(request: request, status: "ready",
          pngSHA256: vision.previewPNG_SHA256,
          pixelSize: .init(x: Double(vision.pixelSize.width), y: Double(vision.pixelSize.height)),
          inkRegions: vision.regions.map(\.contentPoints))
      }
      let receipt = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
      let publication = NotebookPreviewPublication<TargetRenderReceipt>()
      try await withTaskCancellationHandler {
        try await model.performStoreCommand { store in
          try publication.publish(preparing: {
            guard try NotebookStore.pageVisionSourceRevision(store.loadPage(request.target.id)) == request.sourceRevision else { throw PreviewError.sourceChanged }
            return receipt
          }, writing: { try store.saveTargetRender($0) })
        }
      } onCancel: { publication.revoke() }
      return
    }
    guard model.permitsBackgroundPreparation else { throw PreviewError.inputActive }
    let reader = Task.detached(priority: .utility) {
      try store.readTransaction { store in
        guard try store.referenceRevision(target: request.target) == request.sourceRevision else {
          throw PreviewError.sourceChanged
        }
        let files = request.target.kind == .page || request.target.kind == .document
          ? try store.referenceSourceFiles(target: request.target) : [:]
        return (files, try store.workspaceHeader())
      }
    }
    let (files, header) = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
    let source = SceneCompositionSource(store: store, revision: header.cursor, workspaceID: header.workspaceID, documentGeometry: model.documentPaperSizes)
    let target = request.target
    let full: RasterSnapshot
    var camera: SpatialCamera?
    var diagnostics: [RenderDiagnostic] = []
    var buildID: String?
    var programs: [DocumentProgramCheck]?
    var inkRegions: [PageRect] = []
    var inkRaster: RasterSnapshot?
    var documentRaster: RasterLease?
    defer { documentRaster?.release() }
    switch target.kind {
    case .page:
      let page = try await Task.detached(priority: .utility) {
        guard let raw = files["pages/\(target.id.uuidString.lowercased()).json"] else { throw PreviewError.invalidSurface }
        return try raw.decode(PageDocument.self)
      }.value
      full = try await pageCompositeSnapshot(page, programStore: model.store, permitsPreparation: { model.permitsBackgroundPreparation })
      let inkResult = try await PageCompositionRenderer.renderInk(page,
        permitsPreparation: { model.permitsBackgroundPreparation })
      let ink = try await SpatialInkRasterSnapshot.prepare(png: inkResult.png,
        size: .init(width: page.size.width, height: page.size.height),
        permitsPreparation: { model.permitsBackgroundPreparation })
      guard let image = NSImage(data: ink.png) else { throw PreviewError.pngEncoding }
      inkRegions = ink.regions
      inkRaster = RasterSnapshot(image: image, png: ink.png)
      diagnostics = full.diagnostics
    case .document:
      let (document, state) = try await Task.detached(priority: .utility) {
        let suffix = target.id.uuidString.lowercased() + ".json"
        guard let source = files["documents/" + suffix], let state = files["document-states/" + suffix] else {
          throw PreviewError.invalidSurface
        }
        return (try source.decode(DocumentDocument.self), try state.decode(DocumentStateJournal.self))
      }.value
      let preparedDocument = try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: request.pageIndex, programStore: model.store)
      documentRaster = preparedDocument
      full = try await raster(preparedDocument.image)
      let entry = DocumentRenderRegistry.shared.entry(document: document, pageIndex: request.pageIndex)
      diagnostics = entry?.diagnostics ?? []; buildID = entry?.layout.buildID; programs = entry?.programs ?? []
    case .board, .cover:
      let boardID = target.kind == .board ? target.id : target.boardID!
      guard try await source.boardExists(boardID) else { throw PreviewError.invalidSurface }
      let size: CGSize
      let center: WorldPoint
      if target.kind == .cover {
        let itemPresence = SessionPresence(boardID: boardID, mode: .cover, camera: .init(),
          viewport: .init(x: 834, y: 1194), focusedItemID: target.id)
        guard let item = try await source.item(target.id, presence: itemPresence) else { throw PreviewError.invalidSurface }
        let geometry = item.geometry
        size = .init(width: geometry.width, height: geometry.height)
        center = item.center
      } else {
        let region = request.region ?? PageRect(x: 0, y: 0, width: 1024, height: 768)
        size = .init(width: region.width, height: region.height)
        center = (request.worldOrigin ?? .zero).offsetBy(x: region.x + region.width / 2, y: region.y + region.height / 2)
      }
      let projection = SpatialCamera(center: center, scale: 1)
      camera = projection
      let presence = SessionPresence(boardID: boardID, mode: target.kind == .cover ? .cover : .board,
        camera: projection, viewport: .init(x: size.width, y: size.height), focusedItemID: target.kind == .cover ? target.id : nil)
      let renderer = SceneCompositionRenderer(source: source,
        permitsPreparation: { model.permitsBackgroundPreparation })
      let result = target.kind == .cover
        ? try await renderer.renderCover(itemID: target.id, boardID: boardID)
        : try await renderer.render(presence: presence)
      guard let image = NSImage(data: result.png) else { throw PreviewError.pngEncoding }
      full = RasterSnapshot(image: image, png: result.png)
      diagnostics = result.diagnostics
      if let inkResult = try await renderer.renderInk(presence: presence,
        coverID: target.kind == .cover ? target.id : nil) {
        let ink = try await SpatialInkRasterSnapshot.prepare(png: inkResult.png, size: size,
          permitsPreparation: { model.permitsBackgroundPreparation })
        guard let image = NSImage(data: ink.png) else { throw PreviewError.pngEncoding }
        inkRegions = ink.regions
        inkRaster = RasterSnapshot(image: image, png: ink.png)
      }
    case .workspace, .codeFragment: throw PreviewError.invalidSurface
    }
    try await source.validate()
    try Task.checkCancellation()
    guard model.permitsBackgroundPreparation else { throw PreviewError.inputActive }
    let output = target.kind == .board ? full : try crop(full, region: request.region)
    let ink = try inkRaster.map { target.kind == .board ? $0 : try crop($0, region: request.region) }
    let inkFingerprint = ink?.sha256 ?? "empty-ink"
    let png = output.png, outputHash = output.sha256
    let outputCamera = camera, outputDiagnostics = diagnostics, outputRegions = inkRegions, outputBuildID = buildID
    let outputPrograms = programs
    let publication = NotebookPreviewPublication<TargetRenderReceipt>()
    try await withTaskCancellationHandler {
      try await model.performStoreCommand { store in
        try publication.publish(preparing: {
          let latest = try store.workspaceHeader()
          guard latest.cursor == header.cursor, latest.workspaceID == header.workspaceID else { throw PreviewError.sourceChanged }
          guard try store.referenceRevision(target: target) == request.sourceRevision else { throw PreviewError.sourceChanged }
          guard let image = NSBitmapImageRep(data: png) else { throw PreviewError.pngEncoding }
          let fingerprint = request.region == nil ? nil : target.kind == .document ? outputHash
            : try store.regionalFingerprint(request, inkFingerprint: inkFingerprint)
          return .init(request: request, status: "ready", buildID: outputBuildID, pngSHA256: outputHash, referenceFingerprint: fingerprint,
            pixelSize: .init(x: Double(image.pixelsWide), y: Double(image.pixelsHigh)), camera: outputCamera,
            diagnostics: outputDiagnostics, programs: outputPrograms, inkRegions: outputRegions)
        }, writing: { try store.saveTargetRender($0, png: png) })
      }
    } onCancel: { publication.revoke() }
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
    _ page: PageDocument, programStore: NotebookStore,
    permitsPreparation: @escaping @MainActor () -> Bool
  ) async throws -> RasterSnapshot {
    let resources = SceneRenderResources.shared
    var borrowed: RasterLease?
    var preparation: SceneWebRasterPreparation?
    defer { borrowed?.release(); preparation?.close() }
    let graph=page.graphicGraph()
    let result = try await PageCompositionRenderer.render(page, scale: PageVisionRenderer.scale,
      resources: resources, permitsPreparation: permitsPreparation) { element in
      borrowed?.release(); borrowed = nil
      let density=PageVisionRenderer.scale * (graph.placement(element.id).map { NotebookElementPresentation.maximumScale($0.transform) } ?? 1)
      if let image = resources.retainRaster(for: element, minimumScale:density) {
        borrowed = image
        return image
      }
      if preparation == nil {
        preparation = try await SceneWebRasterPreparation.create(resources: resources, permitsPreparation: permitsPreparation)
      }
      guard let preparation else { throw PreviewError.agentSnapshotPending }
      let image = try await preparation.prepare(element, requestedScale:density, programStore: programStore,
        permitsPreparation: permitsPreparation)
      borrowed = image
      return image
    }
    guard let image = NSImage(data: result.png) else { throw PreviewError.pngEncoding }
    return RasterSnapshot(image: image, png: result.png, diagnostics: result.diagnostics)
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

  // These are definitive presentation refusals inside the same accepted writer.
  // File/SQL failures keep their original type and retained retry ownership.
  private enum PreviewError {
    static let agentSnapshotPending = CollaborationError("snapshot_pending", "Изображение элемента ещё готовится.")
    static let documentSnapshotPending = CollaborationError("snapshot_pending", "Изображение документа ещё готовится.")
    static let invalidReceipt = CollaborationError("invalid_snapshot", "Изображение не соответствует источнику.")
    static let invalidSurface = CollaborationError("invalid_snapshot", "Поверхность изображения недоступна.")
    static let sourceChanged = CollaborationError("snapshot_changed", "Источник изображения изменился во время подготовки.")
    static let inputActive = CollaborationError("snapshot_pending", "Изображение ждёт завершения ввода.")
    static let pngEncoding = CollaborationError("invalid_snapshot", "Не удалось подготовить PNG изображения.")
  }
}
