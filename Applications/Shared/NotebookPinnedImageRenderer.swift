import CoreGraphics
import CryptoKit
import NotebookCore
import SwiftUI

struct NotebookPinnedImages: Sendable {
  let images: [UUID: AgentPinnedImage]
  let unavailable: [UUID: String]
  let semanticSelections: [UUID: ProgramSemanticSelection]
}

/// A completed contact may retain ready pixels, but it never starts a program
/// or encodes an image under the Pencil. These leases remain in the scene's
/// existing byte budget, with a finite number of retained source entries.
@MainActor
final class NotebookFrozenVisualSources {
  private typealias Capture = @MainActor () throws -> RasterLease?
  private typealias RegionalCapture = @MainActor () throws -> NotebookSubmittedPixels?
  var attentionPause: NotebookProgramAttentionPause?
  func resumePrograms() { attentionPause?.release(); attentionPause = nil }
  private var rasters: [UUID: [String: RasterLease]]
  private let liveCaptures: [UUID: [String: Capture]]
  private let regionalCaptures: [UUID: RegionalCapture]
  private var submittedRegions: [UUID: NotebookSubmittedPixels] = [:]
  private var failures: [UUID: [String: Error]] = [:]
  private let graphicLayouts: [UUID: NotebookGraphicLayout]
  private let elementPlacements: [UUID:[String:NotebookElementPlacement]]
  private let elementMasks: [UUID: [InkElementErasure]]
  private init(rasters: [UUID: [String: RasterLease]], liveCaptures: [UUID: [String: Capture]] = [:],
    regionalCaptures: [UUID: RegionalCapture] = [:], graphicLayouts: [UUID: NotebookGraphicLayout] = [:],
    elementMasks: [UUID: [InkElementErasure]] = [:],elementPlacements:[UUID:[String:NotebookElementPlacement]] = [:]) {
    self.rasters = rasters; self.liveCaptures = liveCaptures; self.regionalCaptures = regionalCaptures
    self.graphicLayouts = graphicLayouts; self.elementMasks = elementMasks;self.elementPlacements=elementPlacements
  }

  /// Sending fixes both the selected source and the existing visible owner.
  /// No later cache entry or newly created JavaScript context can supply it.
  func freezingForSubmission() -> NotebookFrozenVisualSources {
    let frozen = NotebookFrozenVisualSources(rasters: rasters,graphicLayouts:graphicLayouts,elementMasks:elementMasks,elementPlacements:elementPlacements)
    for (reference, captures) in liveCaptures {
      for (key, capture) in captures {
        frozen.rasters[reference]?[key] = nil
        do {
          if let raster = try capture() { frozen.rasters[reference, default: [:]][key] = raster }
          else { frozen.failures[reference, default: [:]][key] = SceneRenderError.snapshotPending("historical_live_frame_unavailable") }
        } catch { frozen.failures[reference, default: [:]][key] = error }
      }
    }
    for (reference, capture) in regionalCaptures {
      frozen.rasters[reference]?["document-page"] = nil
      do {
        if let pixels = try capture() { frozen.submittedRegions[reference] = pixels }
        else { frozen.failures[reference, default: [:]]["document-page"] = SceneRenderError.snapshotPending("historical_live_frame_unavailable") }
      } catch { frozen.failures[reference, default: [:]]["document-page"] = error }
    }
    return frozen
  }

  static func capture(fragments: [NotebookAttentionSelection.Fragment],
    hierarchy: BoardHierarchy, pages: [UUID: PageDocument], documents: [UUID: DocumentDocument],
    states: [UUID: DocumentStateJournal],
    elementErasures: (SurfaceID, String) -> [InkElementErasure] = { _, _ in [] }, installedSources: [SceneSourceAddress: RasterLease]? = nil,
    capturesLivePrograms: Bool = false, liveSourceAddresses: Set<SceneSourceAddress> = [],
    captureSceneRegion: (@MainActor (NotebookAttentionSelection.Fragment) throws -> NotebookSubmittedPixels?)? = nil,
    resources: SceneRenderResources = .shared) -> NotebookFrozenVisualSources {
    var rasters: [UUID: [String: RasterLease]] = [:]
    var captures: [UUID: [String: Capture]] = [:]
    var regionalCaptures: [UUID: RegionalCapture] = [:]
    var graphics: [UUID: NotebookGraphicLayout] = [:]
    var masks: [UUID: [InkElementErasure]] = [:]
    var placements:[UUID:[String:NotebookElementPlacement]] = [:]
    struct Slot: Hashable { let reference: UUID; let key: String }
    var slots = Set<Slot>()
    func admits(_ reference: UUID, _ key: String) -> Bool {
      let slot = Slot(reference: reference, key: key)
      guard slots.contains(slot) || slots.count < 8 else { return false }
      slots.insert(slot); return true
    }
    func retain(_ source: SceneRasterSource, fragmentID: UUID, key: String) {
      guard admits(fragmentID, key), let raster = resources.retainRaster(for: source) else { return }
      rasters[fragmentID, default: [:]][key] = raster
    }
    for fragment in fragments {
      switch fragment.target.kind {
      case .page:
        guard let page = pages[fragment.target.id] else { continue }
        let graph=page.graphicGraph()
        for element in PageCompositionRenderer.elements(in: page, region: fragment.region, elementID: fragment.elementID) {
          guard let placement=graph.placement(element.id) else { continue }
          placements[fragment.id,default:[:]][element.id]=placement
          if [.graphic,.nativeText].contains(element.kind) { continue }
          let source=agentElementSnapshotSource(element)
          retain(.agent(source), fragmentID: fragment.id, key: element.id)
          #if os(iOS)
          if capturesLivePrograms, element.kind == .web, admits(fragment.id, element.id) {
            let focus = InteractiveElementReference.page(pageID: page.id, elementID: element.id)
            let crop = CGRect(x:fragment.region.x,y:fragment.region.y,width:fragment.region.width,height:fragment.region.height)
              .applying(placement.transform.inverted()).intersection(CGRect(x:0,y:0,width:placement.localSize.x,height:placement.localSize.y))
            captures[fragment.id, default: [:]][element.id] = {
              try AgentWebCoordinator.capturePresented(focus: focus, element: source,
                region: .init(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height), resources: resources)
            }
          }
          #endif
        }
      case .document:
        guard let document = documents[fragment.target.id], let state = states[fragment.target.id],
          let pageIndex = fragment.pageIndex else { continue }
        retain(.document(id: document.id, token: DocumentSnapshotCache.token(document: document, state: state,
          pageIndex: pageIndex)), fragmentID: fragment.id, key: "document-page")
        #if os(iOS)
        if capturesLivePrograms,
          admits(fragment.id, "document-page") {
          let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndex)
          regionalCaptures[fragment.id] = {
            try DocumentPagePresentationOwner.capturePresented(documentID: document.id, pageIndex: pageIndex,
              token: token, region: fragment.region, resources: resources, blockID: fragment.elementID)
          }
        }
        #endif
      case .board, .cover:
        if let id = fragment.elementID {
          let surface: SurfaceID = fragment.target.kind == .board ? .board(fragment.target.id) : .cover(fragment.target.id)
          masks[fragment.id] = elementErasures(surface, id)
        }
        if fragment.elementID == nil, let captureSceneRegion,
          admits(fragment.id, "scene-region") {
          regionalCaptures[fragment.id] = { try captureSceneRegion(fragment) }
          continue
        }
        let boardID = fragment.target.kind == .board ? fragment.target.id : fragment.target.boardID
        let graph=boardID.flatMap { hierarchy.board($0)?.graphicGraph() }
        if let id=fragment.elementID,let graph,let layout=graph.resolve(id).layout {
          graphics[fragment.id]=layout;placements[fragment.id,default:[:]][id]=graph.placement(id);continue
        }
        guard let id = fragment.elementID, let boardID,
          let element = hierarchy.board(boardID)?.element(id:id),
          let placement=graph?.placement(id) else { continue }
        placements[fragment.id,default:[:]][id]=placement
        guard element.kind != .nativeText && element.kind != .graphic else { continue }
        do {
          let plane: SceneCompositionPlane = fragment.target.kind == .cover
            ? .cover(boardID: boardID, itemID: fragment.target.id) : .board(boardID)
          #if os(iOS)
          if capturesLivePrograms, element.kind == .web,
            (installedSources == nil || liveSourceAddresses.contains(.init(plane: plane, elementID: id))), admits(fragment.id, id) {
            let focus = InteractiveElementReference.board(boardID: boardID, elementID: id)
            let source = agentElementSnapshotSource(element)
            let delta = (fragment.worldOrigin ?? .zero).delta(to:placement.origin)
            let crop=CGRect(x:fragment.region.x-delta.x,y:fragment.region.y-delta.y,width:fragment.region.width,height:fragment.region.height)
              .applying(placement.transform.inverted()).intersection(CGRect(x:0,y:0,width:placement.localSize.x,height:placement.localSize.y))
            captures[fragment.id, default: [:]][id] = {
              try AgentWebCoordinator.capturePresented(focus: focus, element: source,
                region: .init(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height), resources: resources)
            }
          }
          #endif
        }
        if let installedSources {
          let plane: SceneCompositionPlane = fragment.target.kind == .cover
            ? .cover(boardID: boardID, itemID: fragment.target.id) : .board(boardID)
          guard admits(fragment.id, id), let installed = installedSources[.init(plane: plane, elementID: id)],
            let actual = installed.source.agentElement,
            SceneRasterSource.agent(actual) == .agent(agentElementSnapshotSource(element)),
            let raster = installed.retainedCopy() else { continue }
          rasters[fragment.id, default: [:]][id] = raster
        } else {
          retain(.agent(agentElementSnapshotSource(element)), fragmentID: fragment.id, key: id)
        }
      case .workspace, .codeFragment: break
      }
    }
    return .init(rasters: rasters, liveCaptures: captures, regionalCaptures: regionalCaptures,graphicLayouts:graphics,elementMasks:masks,elementPlacements:placements)
  }

  func placement(referenceID:UUID,elementID:String) -> NotebookElementPlacement? { elementPlacements[referenceID]?[elementID] }

  func semanticSelection(reference: CollaborationReference) -> ProgramSemanticSelection? {
    if let submitted = submittedRegions[reference.id] { return submitted.semanticSelection }
    guard let id = reference.elementID, let raster = rasters[reference.id]?[id],
      !raster.isReleased, failures[reference.id]?[id] == nil,
      let selection = raster.semanticSelection, let element = raster.source.agentElement,
      let region = reference.region else { return nil }
    guard let placement=elementPlacements[reference.id]?[id] else { return nil }
    let delta=(reference.worldOrigin ?? .zero).delta(to:placement.origin)
    let crop=raster.source.captureRegion ?? .init(x:0,y:0,width:element.frame.width,height:element.frame.height)
    return selection.mapped(from:crop,into:region,
      transform:placement.transform.concatenating(.init(translationX:delta.x,y:delta.y)))

  }

  func erasures(referenceID: UUID) -> [InkElementErasure] { elementMasks[referenceID] ?? [] }

  func graphicLayout(referenceID: UUID) -> NotebookGraphicLayout? { graphicLayouts[referenceID] }

  func submittedRegion(referenceID: UUID) throws -> NotebookSubmittedPixels? {
    if let failure = failures[referenceID]?["document-page"] { throw failure }
    return submittedRegions[referenceID]
  }

  func raster(referenceID: UUID, key: String, source: SceneRasterSource, scale: Double) throws -> RasterLease {
    if let failure = failures[referenceID]?[key] { throw failure }
    guard let raster = rasters[referenceID]?[key], !raster.isReleased,
      raster.pixelScale + 0.000_001 >= scale else {
      throw SceneRenderError.snapshotPending("historical_frame_unavailable")
    }
    if raster.source != source {
      guard let captured = raster.source.agentElement, let expected = source.agentElement,
        SceneRasterSource.agent(captured) == .agent(expected) else {
        throw SceneRenderError.snapshotPending("historical_frame_unavailable")
      }
    }
    return raster
  }

  func pixelScale(referenceID: UUID, maximum: Double) -> Double {
    if let region = submittedRegions[referenceID] { return region.pixelScale }
    return rasters[referenceID]?.reduce(maximum) { available,entry in
      let scale=elementPlacements[referenceID]?[entry.key].map { NotebookElementPresentation.maximumScale($0.transform) } ?? 1
      return min(available,entry.value.pixelScale/scale)
    } ?? maximum
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
    let scale = visuals?.pixelScale(referenceID: reference.id, maximum: Self.scale) ?? Self.scale
    let width = ceil(region.width * scale), height = ceil(region.height * scale)
    guard width.isFinite, height.isFinite, width > 0, height > 0,
      width <= 4096, height <= 4096,
      height <= Double(maximumPixels), width <= Double(maximumPixels) / height else {
      throw SceneRenderError.resourceLimit
    }
    let png: Data
    var presentation: AgentPinnedImage.Presentation?
    switch reference.target.kind {
    case .page:
      guard let page, page.id == reference.target.id, reference.worldOrigin == nil else {
        throw SceneRenderError.snapshotPending("page_source")
      }
      let result = try await PageCompositionRenderer.render(page, region: region, elementID: reference.elementID,
        scale: scale, resources: resources) { element in
        guard let visuals else { throw SceneRenderError.snapshotPending("historical_frame_unavailable") }
        let density=scale * (visuals.placement(referenceID:reference.id,elementID:element.id).map { NotebookElementPresentation.maximumScale($0.transform) } ?? 1)
        return try visuals.raster(referenceID: reference.id, key: element.id, source: .agent(element), scale:density)
      }
      png = result.png
    case .document:
      guard let document, let state, let pageIndex = reference.pageIndex,
        document.id == reference.target.id, state.id == document.id, reference.worldOrigin == nil,
        let visuals else { throw SceneRenderError.snapshotPending("historical_frame_unavailable") }
      let geometry = WorkspaceItemGeometry.document(document.paperSize)
      guard region.x >= 0, region.y >= 0, region.x + region.width <= geometry.width,
        region.y + region.height <= geometry.height else { throw SceneRenderError.snapshotPending("document_region") }
      if let submitted = try visuals.submittedRegion(referenceID: reference.id) {
        guard submitted.region == region else { throw SceneRenderError.snapshotPending("historical_region_unavailable") }
        png = try await submitted.png(); presentation = submitted.presentation
        break
      }
      let source = SceneRasterSource.document(id: document.id,
        token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndex))
      let raster = try visuals.raster(referenceID: reference.id, key: "document-page", source: source, scale: scale)
      let canvas = try await SceneRasterCompositor.create(size: .init(width: region.width, height: region.height),
        scale: scale, resources: resources)
      try await canvas.draw(raster, in: .init(x: -region.x, y: -region.y, width: geometry.width, height: geometry.height))
      png = try await canvas.finishPNG()
    case .board, .cover:
      if let submitted = try visuals?.submittedRegion(referenceID: reference.id) {
        guard submitted.region == region else { throw SceneRenderError.snapshotPending("historical_region_unavailable") }
        png = try await submitted.png(); presentation = submitted.presentation
        break
      }
      guard let element, element.id == reference.elementID,
        element.surface == (reference.target.kind == .board ? .board(reference.target.id) : .cover(reference.target.id)) else {
        // The scene projection is not the full archive. It cannot certify all
        // paint in a free area or a portal by omitting unmounted sources.
        throw SceneRenderError.snapshotPending("historical_scene_region_unavailable")
      }
      let canvas = try await SceneRasterCompositor.create(size: .init(width: region.width, height: region.height),
        scale: scale, resources: resources)
      let placement=visuals?.placement(referenceID:reference.id,elementID:element.id)
      let presentation=placement.map { NotebookElementPresentation(element,placement:$0) }
      let delta = (reference.worldOrigin ?? .zero).delta(to:placement?.origin ?? element.worldOrigin ?? .zero)
      let layout = visuals?.graphicLayout(referenceID:reference.id)
      let erasures = visuals?.erasures(referenceID: reference.id) ?? []
      guard let local = layout?.frame ?? presentation?.frame else { throw SceneRenderError.snapshotPending("historical_element_placement") }
      let frame = CGRect(x: delta.x + local.x - region.x, y: delta.y + local.y - region.y,
        width: local.width, height: local.height)
      let appearance = try await NotebookElementErasureCache.Input(graphic: element.graphic,
        layout: layout, size: presentation?.bodySize ?? frame.size, erasures: erasures).prepared()
      if let graphic = element.graphic {
        guard graphic.connection == nil || layout != nil else { throw SceneRenderError.snapshotPending("historical_graphic_dependencies") }
        try await canvas.drawView(NotebookGraphicView(graphic: graphic,layout:layout,erasures:erasures,appearance:appearance,live:false), size: frame.size, in: frame)
      } else if element.kind == .nativeText {
        try await canvas.drawView(NotebookPlacedElement(presentation:presentation) {
          SpatialTextSnapshot(element:element).snapshotErased(by:erasures,appearance:appearance)
        },size:frame.size,in:frame)
      } else {
        guard let visuals else { throw SceneRenderError.snapshotPending("historical_frame_unavailable") }
        let raster = try visuals.raster(referenceID: reference.id, key: element.id,
          source: .agent(agentElementSnapshotSource(element)), scale:scale * (presentation?.maximumScale ?? 1))
        if let crop = raster.source.captureRegion {
          let captured = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
          guard let presentation else { throw SceneRenderError.snapshotPending("historical_element_placement") }
          let selected=CGRect(x:region.x-delta.x,y:region.y-delta.y,width:region.width,height:region.height)
            .applying(presentation.placement.transform.inverted()).intersection(CGRect(origin:.zero,size:presentation.bodySize))
          guard !selected.isNull, captured.contains(selected) else {
            throw SceneRenderError.snapshotPending("historical_region_unavailable")
          }
          try await canvas.draw(raster,in:captured.applying(presentation.transform).offsetBy(dx:frame.minX,dy:frame.minY),
            erasures:erasures,elementFrame:frame,presentation:presentation)
        } else {
          try await canvas.draw(raster,in:frame,erasures:erasures,presentation:presentation)
        }
      }
      png = try await canvas.finishPNG()
    case .workspace, .codeFragment: throw SceneRenderError.snapshotPending("unbounded_reference")
    }
    try Task.checkCancellation()
    guard png.count <= maximumImageBytes else { throw SceneRenderError.resourceLimit }
    let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    let result = try AgentPinnedImage(referenceID: reference.id, sourceRevision: reference.revision,
      region: region, worldOrigin: reference.worldOrigin, pageIndex: reference.pageIndex,
      pixelWidth: Int(width), pixelHeight: Int(height), pixelsPerPoint: scale, png: png, sha256: hash, presentation: presentation)
    try result.validate(reference: reference)
    return result
  }
}
