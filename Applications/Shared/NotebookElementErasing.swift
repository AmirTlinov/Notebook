import CoreGraphics
import Foundation
import Observation
import NotebookCore

struct NotebookElementErasing {
  let id: UUID
  let surface: SurfaceID
  let samples: InkMeasurements
  let targets: [InkElementTarget]
  var accepted = false
  /// Broad phase of only the newly measured sweep, supplied by the input owner.
  var changedTargets: Set<String>? = nil
  private var retainedCoverage: [String:InkMeasurements] = [:]

  init(id:UUID,surface:SurfaceID,samples:InkMeasurements,targets:[InkElementTarget],
    accepted:Bool = false,changedTargets:Set<String>? = nil) {
    self.id=id;self.surface=surface;self.samples=samples;self.targets=targets
    self.accepted=accepted;self.changedTargets=changedTargets
  }

  mutating func retainUnchangedCoverage(from previous:Self?) {
    guard !accepted,let changedTargets,let previous,
      previous.id == id,previous.surface == surface,
      samples.unchangedPrefix(comparedTo:previous.samples) == previous.samples.count else { return }
    let old=Dictionary(uniqueKeysWithValues:previous.targets.map { ($0.elementID,$0) })
    for target in targets where !changedTargets.contains(target.elementID) && old[target.elementID] == target {
      retainedCoverage[target.elementID]=previous.retainedCoverage[target.elementID] ?? previous.samples
    }
  }

  var masks: [String: [InkElementErasure]] {
    Dictionary(uniqueKeysWithValues: targets.map {
      ($0.elementID, [InkElementErasure(target: $0, measurements: retainedCoverage[$0.elementID] ?? samples)])
    })
  }
}

struct NotebookElementEraserQuery {
  let targets: [InkElementTarget]
  let visitedNodes: Int
}

/// One immutable contact cut of the installed scene. The renderer's retained
/// index owns broad phase; only its local candidate IDs are resolved into
/// exact eraser targets. Accepted insertions and active placement drafts are a
/// small explicit delta, never a reason to walk the whole board.
struct NotebookSpatialEraserSource {
  let boardID: UUID
  let index: WorkspaceSceneIndex
  let graph: NotebookGraphicGraph
  let delta: NotebookSpatialInteractionDelta

  func query(surface: SurfaceID, bounds: WorkspaceSpatialBounds,
    limit: Int = 4_096) throws -> NotebookElementEraserQuery {
    let indexed: WorkspaceSpatialIntersectionQuery
    do {
      guard let result = try index.interactionCandidates(boardID: boardID,
        coverID: surface.kind == .cover ? surface.ownerID : nil,
        bounds: bounds, kinds: .elements, limit: limit) else {
        return .init(targets: [], visitedNodes: 0)
      }
      indexed = result
    } catch {
      throw CollaborationError("eraser_limit",
        "Сотрите меньший участок: в нём слишком много объектов.")
    }
    var ids = Set(indexed.entries.compactMap { entry -> String? in
      guard case .element(let id) = entry.id else { return nil }
      return delta.ids.contains(id) ? nil : id
    })
    let moved: (ids:Set<String>,visitedNodes:Int)
    do {
      moved=try delta.movedCandidateIDs(surface:surface,bounds:bounds,graph:graph,limit:limit)
    } catch {
      throw CollaborationError("eraser_limit",
        "Сотрите меньший участок: в нём слишком много объектов.")
    }
    ids.formUnion(moved.ids)
    ids.formUnion(delta.ids)
    let targets = ids.sorted().compactMap { target(id: $0, surface: surface) }.filter {
      targetBounds($0).intersects(bounds)
    }
    guard targets.count <= limit else {
      throw CollaborationError("eraser_limit",
        "Сотрите меньший участок: в нём слишком много объектов.")
    }
    return .init(targets: targets, visitedNodes: indexed.statistics.visitedNodes + moved.visitedNodes)
  }

  private func target(id: String, surface: SurfaceID) -> InkElementTarget? {
    guard !delta.excluded.contains(id) else { return nil }
    if let node = graph.node(id) {
      guard node.shown, node.surface == surface, let layout = graph.resolve(id).layout else { return nil }
      return .init(elementID: id, frame: layout.frame,
        worldOrigin: surface.kind == .board ? node.origin : nil,
        graphicTransform: node.graphic.transform, elementTransform: layout.elementTransform)
    }
    guard let element = delta.elements[id] ?? index.element(id: id, boardID: boardID),
      element.surface == surface, element.kind != .group, element.graphic == nil,
      let placement = graph.placement(id) else { return nil }
    return NotebookElementPresentation(element, placement: placement)
      .eraserTarget(id: id, wholeElement: element.kind == .web,
        worldOrigin: surface.kind == .board ? placement.origin : nil)
  }

  private func targetBounds(_ target: InkElementTarget) -> WorkspaceSpatialBounds {
    let frame = target.frame
    return .init(origin: (target.worldOrigin ?? .zero).offsetBy(x: frame.x, y: frame.y),
      width: frame.width, height: frame.height)
  }
}

struct NotebookPageEraserSource {
  let page: PageDocument
  let graph: NotebookGraphicGraph
  let changedTargets: [String: InkElementTarget]
  let excludedElementIDs: Set<String>

  func query(bounds: CGRect, limit: Int = 4_096) throws -> NotebookElementEraserQuery {
    let visible=graph.visiblePageGraphics(page.id,in:bounds,limit:limit)
    guard !visible.overflow else {
      throw CollaborationError("eraser_limit",
        "Сотрите меньший участок: в нём слишком много объектов.")
    }
    var ids=Set(visible.layouts.keys);ids.formUnion(visible.placements.keys)
    ids.formUnion(changedTargets.keys)
    let targets=ids.sorted().compactMap { id -> InkElementTarget? in
      guard !excludedElementIDs.contains(id) else { return nil }
      if let changed=changedTargets[id] { return changed }
      if let node=graph.node(id),node.shown,let layout=visible.layouts[id] ?? graph.resolve(id).layout {
        return .init(elementID:id,frame:layout.frame,graphicTransform:node.graphic.transform,
          elementTransform:layout.elementTransform)
      }
      guard let element=page.element(id:id),element.kind != .group,element.graphic == nil,
        let placement=visible.placements[id] ?? graph.placement(id) else { return nil }
      return NotebookElementPresentation(element,placement:placement)
        .eraserTarget(id:id,wholeElement:element.kind == .web)
    }.filter { target in
      let frame=target.frame
      return CGRect(x:frame.x,y:frame.y,width:frame.width,height:frame.height).intersects(bounds)
    }
    guard targets.count <= limit else {
      throw CollaborationError("eraser_limit",
        "Сотрите меньший участок: в нём слишком много объектов.")
    }
    return .init(targets:targets,visitedNodes:visible.visitedIndexNodes)
  }
}

/// One model-owned derived projection for paint, picking and accessibility.
/// Authored erasures remain in their ink actions. No state is persisted here.
@MainActor @Observable final class NotebookElementErasureCache {
  struct Input: Equatable, Sendable {
    let graphic: NotebookGraphic?
    let layout: NotebookGraphicLayout?
    let size: CGSize
    let erasures: [InkElementErasure]
    init(graphic: NotebookGraphic?, layout: NotebookGraphicLayout?, size: CGSize, erasures: [InkElementErasure]) {
      self.graphic = graphic
      self.layout = graphic?.shape == .connector || layout?.projection != nil ? layout : nil
      self.size = size; self.erasures = erasures
    }
    static func == (a: Self, b: Self) -> Bool {
      // Layout curves/heads are local. Translating the element or its camera
      // does not invalidate pixels; resizing or moving a bound endpoint does.
      a.graphic == b.graphic && a.size == b.size && a.erasures == b.erasures
        && a.layout?.curves == b.layout?.curves && a.layout?.heads == b.layout?.heads
        && a.layout?.label == b.layout?.label && a.layout?.projection == b.layout?.projection
    }
    /// Adding opaque erase coverage cannot revive a fully erased body. A
    /// correction, undo, pose or source change is not such an extension.
    func extends(_ old:Input) -> Bool {
      guard graphic == old.graphic,layout == old.layout,size == old.size,
        erasures.count >= old.erasures.count else { return false }
      return zip(old.erasures,erasures).allSatisfy { previous,next in
        previous.target == next.target && next.samples.count >= previous.samples.count
          && (next.samples == previous.samples
            || next.samples.unchangedPrefix(comparedTo:previous.samples) == previous.samples.count)
      }
    }
    func prepare() -> NotebookElementAppearance {
      .init(graphic:graphic,layout:layout,size:size,erasures:erasures)
    }

    /// CPU snapshots must never rasterize the live overlapping triangle mask
    /// on MainActor. Cancellation also revokes the worker's unpublished result.
    func prepared() async throws -> NotebookElementAppearance? {
      guard !erasures.isEmpty else { return nil }
      let worker = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        let value = prepare()
        try Task.checkCancellation()
        return value
      }
      return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
  }
  private struct Address: Hashable { let surface: SurfaceID; let id: String }
  private struct Entry {
    let input: Input
    let token: UInt64
    let task: Task<Void, Never>
    var value: NotebookElementAppearance?
  }
  private actor Preparation {
    func prepare(_ input: Input) -> NotebookElementAppearance? {
      guard !Task.isCancelled else { return nil }
      let value = input.prepare()
      return Task.isCancelled ? nil : value
    }
  }
  @ObservationIgnored private let preparation = Preparation()
  @ObservationIgnored private var entries: [Address: Entry] = [:]
  @ObservationIgnored private var sequence: UInt64 = 0
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private(set) var preparationCount = 0
  private var publication: UInt64 = 0

  func preparedAppearance(surface:SurfaceID,id:String,graphic:NotebookGraphic?,layout:NotebookGraphicLayout?,
    size:CGSize,erasures:[InkElementErasure]) -> NotebookElementAppearance? {
    if erasures.contains(where: { $0.target.wholeElement }) { return .init(graphic:nil,layout:nil,size:size,erasures:erasures) }
    guard let entry=entries[.init(surface:surface,id:id)] else { return nil }
    let input=Input(graphic:graphic,layout:layout,size:size,erasures:erasures)
    return entry.input == input || (entry.value?.state == .erased && input.extends(entry.input)) ? entry.value : nil
  }

  /// A changed input never receives an old appearance. While preparation is
  /// pending, measured ink still paints, but cannot become a ghost hit target.
  func appearance(surface: SurfaceID, id: String, graphic: NotebookGraphic?,
    layout: NotebookGraphicLayout?, size: CGSize, erasures: [InkElementErasure], prepares: Bool = true) -> NotebookElementAppearance? {
    _ = publication
    guard !stopped else { return nil }
    let address = Address(surface:surface,id:id)
    guard !erasures.isEmpty else {
      if entries[address]?.value == nil { entries.removeValue(forKey:address)?.task.cancel() }
      return nil
    }
    if erasures.contains(where: { $0.target.wholeElement }) {
      entries.removeValue(forKey: address)?.task.cancel()
      return .init(graphic: nil, layout: nil, size: size, erasures: erasures)
    }
    let input = Input(graphic:graphic,layout:layout,size:size,erasures:erasures)
    sequence &+= 1
    if let entry = entries[address] {
      if entry.input == input { return entry.value }
      if entry.value?.state == .erased,input.extends(entry.input) {
        // Keep the original coverage proof, not a stale partial hit geometry.
        return entry.value
      }
    }
    entries.removeValue(forKey:address)?.task.cancel()
    // A moving contact already has exact compact GPU coverage. Semantic
    // booleans run once after lift, not once for every intermediate prefix.
    guard prepares else { return nil }
    let token = sequence, worker = preparation
    let task = Task { [weak self] in
      let value = await worker.prepare(input)
      guard !Task.isCancelled, let self, !self.stopped,
        self.entries[address]?.token == token, let value else { return }
      self.entries[address]?.value = value
      self.publication &+= 1
    }
    preparationCount += 1
    entries[address] = Entry(input:input,token:token,task:task,value:nil)
    return nil
  }

  // Lifetime follows the already bounded model workset. An arbitrary entry
  // count would evict still-mounted siblings and restart them on every publish.
  func retain(pages: [UUID: PageDocument]) {
    let owners = pages.mapValues { Set($0.elements.map(\.id)) }
    discard { address in
      address.surface.kind == .page && !(address.surface.ownerID.flatMap { owners[$0] }?.contains(address.id) ?? false)
    }
    self.pages = self.pages.filter { pages[$0.key] != nil }
    projected=projected.filter { $0.key.kind != .page || $0.key.ownerID.flatMap { pages[$0] } != nil }
  }

  func retain(hierarchy: BoardHierarchy?) {
    var owners: [SurfaceID: Set<String>] = [:]
    for node in hierarchy?.boards ?? [] {
      for element in node.board.elements { owners[element.surface, default: []].insert(element.id) }
    }
    discard { $0.surface.kind != .page && !(owners[$0.surface]?.contains($0.id) ?? false) }
  }

  private func discard(where removes: (Address) -> Bool) {
    for address in entries.keys.filter(removes) { entries.removeValue(forKey:address)?.task.cancel() }
  }

  func stop() async {
    stopped = true
    let tasks = entries.values.map(\.task)
    for task in tasks { task.cancel() }
    entries.removeAll(); pages.removeAll(); spatial.removeAll();projected.removeAll();activeTargets=nil
    for task in tasks { await task.value }
  }

  private struct TaggedErasure { let actionID:UUID;let erasure:InkElementErasure }
  private struct PageErasures {
    var stamp:VersionStamp
    var tagged:[String:[TaggedErasure]]
    var targets:[UUID:Set<String>]
    var values:[String:[InkElementErasure]]
    init(stamp:VersionStamp,drawing:PageInkDrawing) {
      self.stamp=stamp;tagged=[:];targets=[:];values=[:]
      for action in drawing.actions where action.isActive && action.tool == .eraser { append(action) }
    }
    mutating func append(_ action:PageInkAction) {
      guard action.isActive,action.tool == .eraser else { return }
      for target in action.elementTargets ?? [] {
        let value=InkElementErasure(target:target,measurements:action.samples)
        tagged[target.elementID,default:[]].append(.init(actionID:action.id,erasure:value))
        values[target.elementID,default:[]].append(value);targets[action.id,default:[]].insert(target.elementID)
      }
    }
    mutating func remove(_ ids:Set<UUID>) {
      for id in ids {
        for target in targets.removeValue(forKey:id) ?? [] {
          tagged[target]?.removeAll { $0.actionID == id }
          if tagged[target]?.isEmpty == true { tagged[target]=nil;values[target]=nil }
          else { values[target]=tagged[target]?.map(\.erasure) }
        }
      }
    }
  }
  @ObservationIgnored private var pages: [UUID: PageErasures] = [:]
  @ObservationIgnored private var spatial: [SurfaceID: [String: [InkElementErasure]]] = [:]
  @ObservationIgnored private var projected: [SurfaceID:[String:[InkElementErasure]]] = [:]
  @ObservationIgnored private var activeTargets: [SurfaceID:Set<String>]?
  @ObservationIgnored private(set) var projectionBuildCount = 0

  func invalidateWorking() { projected.removeAll();activeTargets=nil }

  func isErasing(_ id:String,on surface:SurfaceID,working:[UUID:[NotebookElementErasing]]) -> Bool {
    if activeTargets == nil {
      var ids:[SurfaceID:Set<String>]=[:]
      for contacts in working.values {
        for contact in contacts where !contact.accepted {
          ids[contact.surface,default:[]].formUnion(contact.targets.map(\.elementID))
        }
      }
      activeTargets=ids
    }
    return activeTargets?[surface]?.contains(id) == true
  }

  func projection(on surface:SurfaceID,base:[String:[InkElementErasure]],
    working:[UUID:[NotebookElementErasing]],retains:Bool = true) -> [String:[InkElementErasure]] {
    if retains,let cached=projected[surface] { return cached }
    var result=base
    for contacts in working.values {
      for contact in contacts where contact.surface == surface {
        result.merge(contact.masks) { $0 + $1 }
      }
    }
    projectionBuildCount += 1
    if retains { projected[surface]=result }
    return result
  }

  func record(_ change: PreparedPageInkChange) {
    projected[.page(change.pageID)]=nil
    var entry:PageErasures
    if var cached=pages[change.pageID],cached.stamp == change.baseStamp {
      switch change.mutation {
      case .append(let action): cached.append(action)
      case .remove(let ids): cached.remove(ids)
      }
      entry=cached
    } else { entry=PageErasures(stamp:change.stamp,drawing:change.drawing) }
    entry.stamp=change.stamp;pages[change.pageID]=entry
  }
  func page(_ page: PageDocument) -> [String: [InkElementErasure]] {
    if let cached=pages[page.id],cached.stamp == page.drawingStamp { return cached.values }
    projected[.page(page.id)]=nil
    let entry=PageErasures(stamp:page.drawingStamp,drawing:(try? page.inkDrawing()) ?? .init())
    pages[page.id]=entry
    return entry.values
  }
  func invalidateSpatial() {
    spatial.removeAll();projected=projected.filter { $0.key.kind == .page }
  }
  func masks(on surface: SurfaceID, journal: SpatialInkJournal?) -> [String: [InkElementErasure]] {
    if let cached = spatial[surface] { return cached }
    let masks = journal?.elementErasures(on: surface) ?? [:]
    spatial[surface] = masks
    return masks
  }
}

extension NotebookAppModel {
  func isElementErasing(_ id: String, on surface: SurfaceID) -> Bool {
    elementErasureCache.isErasing(id,on:surface,working:workingElementErasures)
  }

  func pageEraserSource(pageID: UUID) -> NotebookPageEraserSource? {
    guard let page=pages[pageID] else { return nil }
    let graph = graphicGraph(page: page)
    var changed:[String:InkElementTarget]=[:],excluded=Set<String>()
    let references=elementCommandDrafts.keys.compactMap { reference -> EditableElementReference? in
      if case .page(let owner,_)=reference,owner == pageID { return reference };return nil
    }
    for reference in references {
      let id=reference.elementID
      if elementCommandDrafts[reference]?.removed == true { excluded.insert(id);continue }
      guard graph.node(id) == nil,
        let element=nativeElementSource(reference)?.page,element.graphic == nil,
        let presentation=elementPresentation(reference,graph:graph) else { continue }
      changed[id]=presentation.eraserTarget(id:id,wholeElement:element.kind == .web)
    }
    return .init(page:page,graph:graph,changedTargets:changed,excludedElementIDs:excluded)
  }

  func spatialEraserSource(boardID: UUID,
    cohort: SceneCompositionCohort) -> NotebookSpatialEraserSource {
    let baseGraph=cohort.frame.index.graphicGraph(boardID:boardID)
    let graph = interactionGraphicGraph(boardID: boardID, cohort: cohort)
    let delta=spatialInteractionDelta(boardID:boardID,graph:graph,baseGraph:baseGraph)
    return .init(boardID: boardID, index: cohort.frame.index, graph: graph,
      delta:delta)
  }

  func updateElementErasing(_ contact: [NotebookElementErasing], id: UUID) {
    // Once lift transfers this contact to the model, an old paper's refresh
    // or teardown cannot retract it while preparation is still pending.
    guard workingElementErasures[id]?.contains(where: \.accepted) != true else { return }
    let previous=workingElementErasures[id] ?? []
    // Preserve segment positions even when an earlier span has no targets.
    // The renderer receives a new prefix only where the new sweep can matter.
    let visible = contact.enumerated().map { index,contact in
      var next=contact
      next.retainUnchangedCoverage(from:previous.indices.contains(index) ? previous[index] : nil)
      return next
    }
    if visible.allSatisfy({ $0.targets.isEmpty }) {
      // An inactive canvas may cancel during every SwiftUI update. A no-op
      // must not publish another update and strand the opened paper in a loop.
      if workingElementErasures[id] != nil { workingElementErasures[id] = nil }
    } else { workingElementErasures[id] = visible }
  }

  func elementErasures(on surface: SurfaceID, fallback: SpatialInkJournal? = nil) -> [String: [InkElementErasure]] {
    var result: [String: [InkElementErasure]]
    if surface.kind == .page, let id = surface.ownerID, let page = pages[id] {
      result = elementErasureCache.page(page)
    } else if loadedInkSurfaces.contains(surface) || fallback == nil {
      result = elementErasureCache.masks(on: surface, journal: spatialInk)
    } else { result = fallback?.elementErasures(on: surface) ?? [:] }
    return elementErasureCache.projection(on:surface,base:result,working:workingElementErasures,
      retains:surface.kind == .page || loadedInkSurfaces.contains(surface) || fallback == nil)
  }
}

private extension NotebookElementPresentation {
  /// Freeze the same full local body that receives the mask. Text's fitted
  /// envelope can be narrower than its layout width and taller than its source.
  func eraserTarget(id:String,wholeElement:Bool,worldOrigin:WorldPoint? = nil) -> InkElementTarget {
    let t=placement.transform,size=bodySize,bounds=CGRect(origin:.zero,size:size).applying(t)
    let basis=NotebookGraphicTransform(a:t.a*size.width/bounds.width,b:t.b*size.width/bounds.height,
      c:t.c*size.height/bounds.width,d:t.d*size.height/bounds.height,
      tx:(t.tx-bounds.minX)/bounds.width,ty:(t.ty-bounds.minY)/bounds.height)
    return .init(elementID:id,frame:.init(x:bounds.minX,y:bounds.minY,width:bounds.width,height:bounds.height),
      worldOrigin:worldOrigin,wholeElement:wholeElement,elementTransform:basis == .identity ? nil : basis)
  }
}
