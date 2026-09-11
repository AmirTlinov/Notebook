import CoreGraphics
import CryptoKit
import NotebookCore
import SwiftUI

struct NotebookPinnedImages: Sendable {
  let images: [UUID: AgentPinnedImage]
  let unavailable: [UUID: String]
}

/// A completed contact may retain ready pixels, but it never starts a program
/// or encodes an image under the Pencil. These leases remain in the scene's
/// existing byte budget, with a finite number of retained source entries.
@MainActor
final class NotebookFrozenVisualSources {
  private let rasters: [UUID: [String: RasterLease]]
  private init(rasters: [UUID: [String: RasterLease]]) { self.rasters = rasters }

  static func capture(fragments: [NotebookAttentionSelection.Fragment],
    hierarchy: BoardHierarchy, pages: [UUID: PageDocument], documents: [UUID: DocumentDocument],
    states: [UUID: DocumentStateJournal], resources: SceneRenderResources = .shared) -> NotebookFrozenVisualSources {
    var rasters: [UUID: [String: RasterLease]] = [:]
    var retained = 0
    func retain(_ source: SceneRasterSource, fragmentID: UUID, key: String) {
      guard retained < 8, let raster = resources.retainRaster(for: source) else { return }
      rasters[fragmentID, default: [:]][key] = raster
      retained += 1
    }
    for fragment in fragments {
      switch fragment.target.kind {
      case .page:
        guard let page = pages[fragment.target.id] else { continue }
        for element in PageCompositionRenderer.elements(in: page, region: fragment.region, elementID: fragment.elementID) {
          retain(.agent(element), fragmentID: fragment.id, key: element.id)
        }
      case .document:
        guard let document = documents[fragment.target.id], let state = states[fragment.target.id],
          let pageIndex = fragment.pageIndex else { continue }
        retain(.document(id: document.id, token: DocumentSnapshotCache.token(document: document, state: state,
          pageIndex: pageIndex)), fragmentID: fragment.id, key: "document-page")
      case .board, .cover:
        let boardID = fragment.target.kind == .board ? fragment.target.id : fragment.target.boardID
        guard let id = fragment.elementID, let boardID,
          let element = hierarchy.board(boardID)?.elements.first(where: { $0.id == id }),
          element.kind != .nativeText else { continue }
        retain(.agent(agentElementSnapshotSource(element)), fragmentID: fragment.id, key: id)
      case .workspace, .codeFragment: break
      }
    }
    return .init(rasters: rasters)
  }

  func raster(referenceID: UUID, key: String, source: SceneRasterSource, scale: Double) throws -> RasterLease {
    guard let raster = rasters[referenceID]?[key], raster.image(for: source, minimumScale: scale) != nil else {
      throw SceneRenderError.snapshotPending("historical_frame_unavailable")
    }
    return raster
  }
}

/// Only retained physical values and retained program pixels enter this path.
/// SQL, the current selection, new WebKit execution and bounded overview tiles
/// are deliberately not possible inputs to a question's frozen evidence.
@MainActor
enum NotebookPinnedImageRenderer {
  static let scale = 2.0
  static let maximumPixels = 4_000_000
  static let maximumImageBytes = 2_097_152
  static let maximumTotalBytes = 4_194_304

  static func render(reference: CollaborationReference, page: PageDocument?, document: DocumentDocument?,
    state: DocumentStateJournal?, element: SpatialElement?, visuals: NotebookFrozenVisualSources?,
    resources: SceneRenderResources) async throws -> AgentPinnedImage {
    guard let region = reference.region else { throw SceneRenderError.snapshotPending("unbounded_reference") }
    let width = ceil(region.width * scale), height = ceil(region.height * scale)
    guard width.isFinite, height.isFinite, width > 0, height > 0,
      width <= 4096, height <= 4096,
      height <= Double(maximumPixels), width <= Double(maximumPixels) / height else {
      throw SceneRenderError.resourceLimit
    }
    let png: Data
    switch reference.target.kind {
    case .page:
      guard let page, page.id == reference.target.id, reference.worldOrigin == nil else {
        throw SceneRenderError.snapshotPending("page_source")
      }
      let result = try await PageCompositionRenderer.render(page, region: region, elementID: reference.elementID,
        scale: scale, resources: resources) { element in
        guard let visuals else { throw SceneRenderError.snapshotPending("historical_frame_unavailable") }
        return try visuals.raster(referenceID: reference.id, key: element.id, source: .agent(element), scale: scale)
      }
      png = result.png
    case .document:
      guard let document, let state, let pageIndex = reference.pageIndex,
        document.id == reference.target.id, state.id == document.id, reference.worldOrigin == nil,
        let visuals else { throw SceneRenderError.snapshotPending("historical_frame_unavailable") }
      let geometry = WorkspaceItemGeometry.document(document.paperSize)
      guard region.x >= 0, region.y >= 0, region.x + region.width <= geometry.width,
        region.y + region.height <= geometry.height else { throw SceneRenderError.snapshotPending("document_region") }
      let source = SceneRasterSource.document(id: document.id,
        token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndex))
      let raster = try visuals.raster(referenceID: reference.id, key: "document-page", source: source, scale: scale)
      let canvas = try await SceneRasterCompositor.create(size: .init(width: region.width, height: region.height),
        scale: scale, resources: resources)
      try await canvas.draw(raster, in: .init(x: -region.x, y: -region.y, width: geometry.width, height: geometry.height))
      png = try await canvas.finishPNG()
    case .board, .cover:
      guard let element, element.id == reference.elementID,
        element.surface == (reference.target.kind == .board ? .board(reference.target.id) : .cover(reference.target.id)) else {
        // The scene projection is not the full archive. It cannot certify all
        // paint in a free area or a portal by omitting unmounted sources.
        throw SceneRenderError.snapshotPending("historical_scene_region_unavailable")
      }
      let canvas = try await SceneRasterCompositor.create(size: .init(width: region.width, height: region.height),
        scale: scale, resources: resources)
      let delta = (reference.worldOrigin ?? .zero).delta(to: element.worldOrigin ?? .zero)
      let frame = CGRect(x: delta.x + element.frame.x - region.x, y: delta.y + element.frame.y - region.y,
        width: element.frame.width, height: element.frame.height)
      if element.kind == .nativeText {
        try await canvas.drawView(SpatialTextSnapshot(element: element), size: frame.size, in: frame)
      } else {
        guard let visuals else { throw SceneRenderError.snapshotPending("historical_frame_unavailable") }
        let raster = try visuals.raster(referenceID: reference.id, key: element.id,
          source: .agent(agentElementSnapshotSource(element)), scale: scale)
        try await canvas.draw(raster, in: frame)
      }
      png = try await canvas.finishPNG()
    case .workspace, .codeFragment: throw SceneRenderError.snapshotPending("unbounded_reference")
    }
    try Task.checkCancellation()
    guard png.count <= maximumImageBytes else { throw SceneRenderError.resourceLimit }
    let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    let result = try AgentPinnedImage(referenceID: reference.id, sourceRevision: reference.revision,
      region: region, worldOrigin: reference.worldOrigin, pageIndex: reference.pageIndex,
      pixelWidth: Int(width), pixelHeight: Int(height), pixelsPerPoint: scale, png: png, sha256: hash)
    try result.validate(reference: reference)
    return result
  }
}
