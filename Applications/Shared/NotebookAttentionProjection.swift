import NotebookCore
import SwiftUI

/// References use owner-local points. This projection follows the same item
/// centers and stack fan as the visible scene, so moving an item moves its mark.
@MainActor
enum NotebookAttentionProjection {
  /// Screen-space forgiveness around visible geometry, not an enlarged object.
  /// Pending human edits and settled scene picking use the same boundary.
  static let elementHitPadding: Double = 6
  static func frame(_ reference: CollaborationReference, model: NotebookAppModel, presence: SessionPresence) -> CGRect? {
    frame(target: reference.target, elementID: reference.elementID, region: reference.region,
      worldOrigin: reference.worldOrigin, pageIndex: reference.pageIndex, model: model, presence: presence)
  }

  static func agentFeedback(_ subject: NotebookAgentFeedbackChange.Subject, model: NotebookAppModel,
    presence: SessionPresence, includingOcclusion: Bool = true) -> NotebookAgentFeedbackSurface? {
    let reference = subject.reference
    guard let rect = frame(target:reference.target,elementID:reference.elementID,region:reference.region,
      worldOrigin:reference.worldOrigin,pageIndex:reference.pageIndex,model:model,presence:presence,minimumSide:0),
      rect.width > 0, rect.height > 0 else { return nil }
    var result = NotebookAgentFeedbackSurface(rect:rect,scale:presence.camera.scale)
    func finished(_ value: NotebookAgentFeedbackSurface) -> NotebookAgentFeedbackSurface {
      guard includingOcclusion, let cohort = model.compositionTiles.published else { return value }
      var result = value
      let workset = model.presentedWorkset(cohort:cohort,boardID:presence.boardID,presence:presence)
      if reference.target.kind == .board || reference.target.kind == .cover {
        let ownItem = workset.items.first { $0.id == reference.target.id }
        result.occludedRects = workset.items.filter { item in
          reference.target.kind == .board || ownItem.map { WorkspaceSceneProjection.isPaintedBelow($0,item,in:presence) } == true
        }.compactMap { item in
          let box = item.geometry.screenFrame(center:item.center,camera:presence.camera,viewport:presence.viewport)
          let rect = CGRect(x:box.x,y:box.y,width:box.width,height:box.height)
          return rect.intersects(value.rect) ? rect : nil
        }
      }
      if let id = reference.elementID, reference.target.kind != .document {
        let later: [String]
        if reference.target.kind == .page, let elements = model.pages[reference.target.id]?.elements,
          let index = elements.firstIndex(where: { $0.id == id }) {
          later = elements.dropFirst(index+1).map(\.id)
        } else {
          let surface: SurfaceID = reference.target.kind == .cover ? .cover(reference.target.id) : .board(reference.target.id)
          let elements = reference.target.kind == .cover
            ? model.presentedCoverElements(cohort:cohort,boardID:presence.boardID,itemID:reference.target.id) : workset.elements
          let position = cohort.frame.index.paintEntry(id:.element(id),boardID:presence.boardID,coverID:reference.target.kind == .cover ? reference.target.id : nil)
          later = elements.filter { element in
            guard element.surface == surface, let position,
              let next = cohort.frame.index.paintEntry(id:.element(element.id),boardID:presence.boardID,coverID:reference.target.kind == .cover ? reference.target.id : nil) else { return false }
            return ScenePaintPosition(entry:position) < ScenePaintPosition(entry:next)
          }.map(\.id)
        }
        result.occluders = later.compactMap { id in
          let next = NotebookAgentFeedbackChange.Subject(reference:.init(target:reference.target,elementID:id,revision:reference.revision),expected:subject.expected)
          guard let mask = agentFeedback(next,model:model,presence:presence,includingOcclusion:false), mask.rect.intersects(value.rect) else { return nil }
          return mask
        }
      }
      return result
    }
    if reference.target.kind != .board {
      result.clipRect = frame(target:reference.target,elementID:nil,region:nil,worldOrigin:nil,
        pageIndex:reference.pageIndex,model:model,presence:presence,minimumSide:0)
    }
    if reference.target.kind == .document {
      if reference.elementID == nil, reference.region != nil { result.isSurface = true; return finished(result) }
      guard let id = reference.elementID, let document = model.documents[reference.target.id],
        let block = document.blocks.first(where: { $0.id == id }) else { return nil }
      if block.kind == .interactive { result.isSurface = true; return finished(result) }
      guard let state = model.documentStates[document.id],
        let paper = DocumentRenderRegistry.shared.installedPaper(document: document, state: state, pageIndex: presence.documentPageIndex),
        let page = result.clipRect else { return nil }
      result.paper = paper
      result.paperOrigin = .init(x: (page.minX-rect.minX)/result.scale, y: (page.minY-rect.minY)/result.scale)
      result.clipRect = rect.intersection(page)
      return finished(result)
    }
    if let strokeID = subject.strokeID {
      guard let ink = NotebookAgentFeedbackInk.path(strokeID:strokeID,reference:reference,model:model) else { return nil }
      result.ink = ink
      return finished(result)
    }
    guard let id = reference.elementID else { result.isSurface = true; return finished(result) }
    let editable: EditableElementReference, surface: SurfaceID
    switch reference.target.kind {
    case .page:
      editable = .page(pageID:reference.target.id,elementID:id); surface = .page(reference.target.id)
      guard let element = model.pages[reference.target.id]?.element(id:id) else { return nil }
      result.graphic = element.graphic
      if element.graphic == nil {
        result.isSurface = element.kind == .web
        if !result.isSurface { result.raster = SceneRenderResources.shared.retainRaster(for:.agent(element)) }
      }
    case .board, .cover:
      editable = .spatial(boardID:presence.boardID,elementID:id)
      guard let cohort = model.compositionTiles.published,
        let element = model.presentedElement(editable,cohort:cohort) else { return nil }
      surface = element.surface; result.graphic = element.graphic
      if element.kind == .nativeText { result.text = element }
      else if element.graphic == nil {
        result.isSurface = element.kind == .web
        let plane: SceneCompositionPlane = reference.target.kind == .cover
          ? .cover(boardID:presence.boardID,itemID:reference.target.id) : .board(reference.target.id)
        result.raster = result.isSurface ? nil : cohort.sourceRasters[.init(plane:plane,elementID:id)]
      }
    case .document, .workspace, .codeFragment: return nil
    }
    if result.graphic != nil {
      guard let layout = model.graphicLayout(editable) else { return nil }
      result.layout = layout
    }
    result.erasures = model.elementErasures(on:surface,fallback:model.compositionTiles.published?.liveData.ink)[id] ?? []
    return finished(result)
  }

  /// The admitted editor has geometry before its element reaches a published
  /// scene. Painting and outside-tap routing must use this same live frame.
  static func nativeTextEditingFrame(_ target: NotebookNativeTextTarget, model: NotebookAppModel,
    presence: SessionPresence) -> CGRect? {
    guard let presentation=model.nativeTextEditingPresentation(target) else { return nil }
    let scale = presence.camera.scale
    let origin: CGPoint
    if target.address.surface.kind == .board {
      guard target.address.boardID == presence.boardID else { return nil }
      let point = presence.camera.worldToScreen(presentation.placement.origin,viewport:presence.viewport)
      origin = .init(x:point.x,y:point.y)
    } else {
      guard let rect = frame(.init(target:target.address.target,revision:""),model:model,presence:presence) else { return nil }
      origin = rect.origin
    }
    return .init(x:origin.x+presentation.bounds.minX*scale,y:origin.y+presentation.bounds.minY*scale,
      width:presentation.bounds.width*scale,height:presentation.bounds.height*scale)
  }

  /// Project every typed member through its real physical surface. Raw member
  /// IDs are never passed to an authored-element lookup to obtain a rectangle.
  static func selectionFrames(model:NotebookAppModel,presence:SessionPresence) -> [CGRect]? {
    var frames:[CGRect]=[]
    for reference in model.selectionSession.elements {
      guard let frame=editingFrame(reference,model:model,presence:presence) else { return nil }
      frames.append(frame)
    }
    let poses=selectedInkPoses(model:model)
    for raw in model.selectionSession.ink {
      let local=poses[raw.memberID]?.frame ?? raw.material.frame
      guard let value=frame(target:raw.address.target,elementID:nil,region:local,
        worldOrigin:raw.address.worldOrigin,pageIndex:nil,model:model,presence:presence,minimumSide:0) else { return nil }
      frames.append(value)
    }
    for selected in model.selectionSession.items {
      guard selected.boardID == presence.boardID,let cohort=model.compositionTiles.published,
        let item=model.presentedItem(id:selected.itemID,cohort:cohort,presence:presence)
          ?? cohort.frame.index.renderedItem(id:selected.itemID,presence:presence) else { return nil }
      let frame=item.geometry.screenFrame(center:item.center,camera:presence.camera,viewport:presence.viewport)
      frames.append(.init(x:frame.x,y:frame.y,width:frame.width,height:frame.height))
    }
    return frames
  }

  /// Resolve once per projection: raw controls and hit testing share the same
  /// installed poses, including a retiring owner after the live contact ends.
  /// Typed identity excludes a fresh choice of the same journal action.
  static func selectedInkPoses(model:NotebookAppModel)->[String:NotebookGraphicSelection.Edit] {
    let selected=Dictionary(uniqueKeysWithValues:model.selectionSession.ink.map{($0.memberID,$0)})
    guard !selected.isEmpty else {return [:]}
    var poses=Dictionary(uniqueKeysWithValues:(model.selectionSession.manipulation?.presentedSelectedEdits ?? [])
      .filter{selected[$0.id] != nil}.map{($0.id,$0)})
    var visited=Set<UUID>()
    for working in model.workingGraphics {
      guard let owner=working.inkPresentation,owner.retiring,owner.holdsPresentation,
        visited.insert(owner.id).inserted else {continue}
      let matching=Set(owner.source.ink.compactMap { raw -> String? in
        guard let current=selected[raw.memberID],current.key == raw.key,current.revision == raw.revision,
          current.address.surface == owner.source.address.surface else {return nil}
        return raw.memberID
      })
      for edit in owner.presentedEdits ?? [] where matching.contains(edit.id) && poses[edit.id] == nil {poses[edit.id]=edit}
    }
    return poses
  }

  static func editingFrame(_ reference: EditableElementReference, model: NotebookAppModel, presence: SessionPresence,
    layout: NotebookGraphicLayout? = nil) -> CGRect? {
    if let region=model.selectionSession.region,region.reference == reference {
      let f=model.selectionSession.manipulation.flatMap { $0.reference == reference ? $0.presentedFrame : nil }
      let local=f.map { PageRect(x:$0.minX,y:$0.minY,width:$0.width,height:$0.height) } ?? region.frame
      return frame(target:region.address.target,elementID:nil,region:local,
        worldOrigin:region.address.worldOrigin,pageIndex:nil,model:model,presence:presence,minimumSide:0)
    }
    let resolved=layout ?? model.graphicLayout(reference)
    if let mask=model.graphicElement(reference)?.mask,let local=resolved?.selectionFrame(mask:mask),
      let source=model.nativeElementSource(reference) {
      return frame(target:source.target,elementID:nil,region:local,
        worldOrigin:source.target.kind == .board ? resolved?.origin : nil,pageIndex:nil,
        model:model,presence:presence,minimumSide:0)
    }
    // Accepted input is already the model owner even while the published scene
    // still contains the preceding raster cohort. Project its live graph node
    // through the ordinary surface frame instead of waiting for persistence.
    if let working = model.acceptedWorkingGraphic(reference) {
      let local = resolved?.frame ?? working.frame
      let origin = resolved?.origin ?? working.worldOrigin
      guard let owner=working.surface.ownerID else { return nil }
      let target:CollaborationTarget
      if working.surface.kind == .page { target = .init(kind:.page,id:owner) }
      else if working.surface.kind == .board {
        guard owner == presence.boardID else { return nil };target = .init(kind:.board,id:owner)
      } else {
        guard case .spatial(let board,_) = reference,board == presence.boardID else { return nil }
        target = .init(kind:.cover,id:owner,boardID:board)
      }
      return frame(target:target,elementID:nil,region:local,worldOrigin:origin,pageIndex:nil,
        model:model,presence:presence,minimumSide:0)
    }
    let target: CollaborationTarget, id: String
    switch reference {
    case .page(let pageID, let elementID): target = .init(kind: .page, id: pageID); id = elementID
    case .spatial(let boardID, let elementID):
      guard boardID == presence.boardID,
        let cohort = model.compositionTiles.published,
        let element = model.presentedElement(reference, cohort: cohort) ?? cohort.frame.index.element(id:elementID,boardID:boardID).flatMap({ $0.kind == .group ? $0 : nil }), let owner = element.surface.ownerID else { return nil }
      target = .init(kind: element.surface.kind == .cover ? .cover : .board, id: owner, boardID: boardID); id = elementID
    }
    return frame(target: target, elementID: id, region: nil, worldOrigin: nil, pageIndex: nil, model: model, presence: presence, minimumSide: 0, graphicLayout:layout)
  }

  private static func frame(target: CollaborationTarget, elementID: String?, region: PageRect?,
    worldOrigin: WorldPoint?, pageIndex: Int?, model: NotebookAppModel, presence: SessionPresence, minimumSide: Double = 8,
    graphicLayout: NotebookGraphicLayout? = nil) -> CGRect? {
    guard let workspace = model.workspace else { return nil }
    let cohort = model.compositionTiles.published
    let index = cohort?.frame.index
    var local = region ?? PageRect(x:0,y:0,width:1,height:1)
    if target.kind == .board {
      guard target.id == presence.boardID, let cohort, let index else { return nil }
      var origin = worldOrigin ?? .zero
      if let id = elementID {
        guard let element = model.presentedElement(.spatial(boardID: presence.boardID, elementID: id), cohort: cohort) ?? index.element(id:id,boardID:presence.boardID).flatMap({ $0.kind == .group ? $0 : nil }),
          element.surface == .board(target.id) else { return nil }
        local = model.elementPresentationFrame(.spatial(boardID:presence.boardID,elementID:id),
          fallback:.init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height))
        if element.kind == .group {
          guard let group=model.groupManipulationGeometry(.spatial(boardID:presence.boardID,elementID:id)) else { return nil }
          local = .init(x:group.bounds.minX,y:group.bounds.minY,width:group.bounds.width,height:group.bounds.height);origin=group.placement.origin
        } else if element.graphic != nil {
          guard let layout = graphicLayout ?? model.graphicLayout(.spatial(boardID:presence.boardID,elementID:id)) else { return nil }
          local = layout.frame;origin = layout.origin
        } else { origin = model.elementPresentation(.spatial(boardID:presence.boardID,elementID:id))?.placement.origin ?? element.worldOrigin ?? .zero }
      }
      let top = presence.camera.worldToScreen(origin.offsetBy(x:local.x,y:local.y),viewport:presence.viewport)
      return .init(x:top.x,y:top.y,width:max(minimumSide,local.width * presence.camera.scale),height:max(minimumSide,local.height * presence.camera.scale))
    }
    let itemID: UUID
    if target.kind == .page {
      guard let ownerID = model.notebookPageOwner(target.id) ?? index?.pageOwner(pageID: target.id),
        workspace.selectedPageID == target.id, presence.mode == .page else { return nil }
      itemID = ownerID
      if let id = elementID {
        guard let element = model.pages[target.id]?.element(id:id) else { return nil }
        local = model.elementPresentationFrame(.page(pageID:target.id,elementID:id),fallback:element.frame)
        if element.kind == .group {
          guard let group=model.groupManipulationGeometry(.page(pageID:target.id,elementID:id)) else { return nil }
          local = .init(x:group.bounds.minX,y:group.bounds.minY,width:group.bounds.width,height:group.bounds.height)
        } else if element.graphic != nil {
          guard let layout = graphicLayout ?? model.graphicLayout(.page(pageID:target.id,elementID:id)) else { return nil }
          local = layout.frame
        }
      }
    } else {
      itemID = target.id
      if target.kind == .document {
        guard presence.mode == .document, presence.focusedItemID == itemID else { return nil }
        if let id = elementID, let document = model.documents[itemID] {
          guard let region = DocumentRenderRegistry.shared.regions(document: document).first(where: { $0.id == id && $0.pageIndex == presence.documentPageIndex }) else { return nil }
          local = region.frame
        } else if let page = pageIndex, page != presence.documentPageIndex { return nil }
      } else if target.kind == .cover {
        guard presence.mode == .board || presence.mode == .cover else { return nil }
        if let id = elementID {
          guard let cohort, let element = model.presentedElement(.spatial(boardID: presence.boardID, elementID: id), cohort: cohort),
            element.surface == .cover(itemID) else { return nil }
          local = model.elementPresentationFrame(.spatial(boardID:presence.boardID,elementID:id),
            fallback:.init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height))
          if element.kind == .group {
            guard let group=model.groupManipulationGeometry(.spatial(boardID:presence.boardID,elementID:id)) else { return nil }
            local = .init(x:group.bounds.minX,y:group.bounds.minY,width:group.bounds.width,height:group.bounds.height)
          } else if element.graphic != nil {
            guard let layout = graphicLayout ?? model.graphicLayout(.spatial(boardID:presence.boardID,elementID:id)) else { return nil }
            local = layout.frame
          }
        }
      } else { return nil }
    }
    let box: SpatialRect
    #if os(macOS)
    if target.kind == .page || target.kind == .document {
      guard presence.focusedItemID == itemID, let paper = readingPaperFrame(model:model,presence:presence) else { return nil }
      box = .init(x:paper.minX,y:paper.minY,width:paper.width,height:paper.height)
    } else {
      guard let cohort, let rendered = model.presentedItem(id:itemID,cohort:cohort,presence:presence) else { return nil }
      box = rendered.geometry.screenFrame(center:rendered.center,camera:presence.camera,viewport:presence.viewport)
    }
    #else
    guard let cohort, let rendered = model.presentedItem(id:itemID,cohort:cohort,presence:presence) else { return nil }
    box = rendered.geometry.screenFrame(center:rendered.center,camera:presence.camera,viewport:presence.viewport)
    #endif
    if region == nil && elementID == nil { local = .init(x:0,y:0,width:box.width/presence.camera.scale,height:box.height/presence.camera.scale) }
    return .init(x:box.x + local.x * presence.camera.scale,y:box.y + local.y * presence.camera.scale,
      width:max(minimumSide,local.width * presence.camera.scale),height:max(minimumSide,local.height * presence.camera.scale))
  }

  private struct CaptureSources {
    let workset: WorkspaceSceneWorkset
    let workspace: WorkspaceIndex
    let hierarchy: BoardHierarchy
    let ink: SpatialInkJournal
    var pages: [UUID: PageDocument]
    var documents: [UUID: DocumentDocument]
    var states: [UUID: DocumentStateJournal]
    let selectedPageID: UUID?
    var materialGraph: ((UUID)->NotebookGraphicGraph)? = nil
    var working: [SpatialElement] = []
    let erasures: (SurfaceID) -> [String: [InkElementErasure]]
    let appearance: (SurfaceID, String, NotebookGraphic?, NotebookGraphicLayout?, CGSize, [InkElementErasure]) -> NotebookElementAppearance?
  }

  #if os(iOS)
  struct ProgramChoice: Identifiable {
    let target: CollaborationTarget
    let elementID: String
    let point: CGPoint
    let label: String
    var id: String { target.id.uuidString + "/" + elementID }
  }

  /// The existing material menu can select a program whose local scroll or
  /// canvas legitimately owns every finger contact. It uses the same physical
  /// projection and attention capture as pointing, not a DOM selection channel.
  static func programChoices(model: NotebookAppModel) -> [ProgramChoice] {
    guard let presence = model.presence, let cohort = model.compositionTiles.published,
      cohort.isPaintInstalled else { return [] }
    var candidates: [(CollaborationTarget, String, String)] = []
    if presence.mode == .document, let id = presence.focusedItemID, let document = model.documents[id] {
      candidates = document.blocks.filter { $0.kind == .interactive }.map { (.init(kind: .document, id: id), $0.id, "Программа · " + $0.id) }
    } else if presence.mode == .page, let id = presence.notebookPageID ?? model.workspace?.selectedPageID,
      let page = model.pages[id] {
      candidates = page.elements.filter { $0.kind == .web }.map { (.init(kind: .page, id: id), $0.id, $0.source) }
    } else if presence.mode == .cover, let id = presence.focusedItemID {
      candidates = model.presentedCoverElements(cohort: cohort, boardID: presence.boardID, itemID: id)
        .filter { $0.kind == .web }.map { (.init(kind: .cover, id: id, boardID: presence.boardID), $0.id, $0.source) }
    } else {
      candidates = model.presentedWorkset(cohort: cohort, boardID: presence.boardID, presence: presence).elements
        .filter { $0.kind == .web && $0.surface.kind == .board }
        .map { (.init(kind: .board, id: presence.boardID), $0.id, $0.source) }
    }
    let viewport = CGRect(x: 0, y: 0, width: presence.viewport.x, height: presence.viewport.y)
    return Array(candidates.lazy.compactMap { target, id, label -> ProgramChoice? in
      guard let box = frame(target: target, elementID: id, region: nil, worldOrigin: nil,
        pageIndex: target.kind == .document ? presence.documentPageIndex : nil,
        model: model, presence: presence, minimumSide: 0) else { return nil }
      let visible = box.intersection(viewport)
      guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
      return .init(target: target, elementID: id, point: .init(x: visible.midX, y: visible.midY),
        label: label.isEmpty ? "Программа" : String(label.prefix(80)))
    }.prefix(32))
  }

  static func captureProgram(_ choice: ProgramChoice, model: NotebookAppModel) -> NotebookAttentionSelection? {
    guard let presence = model.presence, let cohort = model.compositionTiles.published,
      let selected = capture(start: choice.point, end: choice.point, model: model, presence: presence,
        cohort: cohort, installedInk: model.compositionTiles.surfaceRegistry.installedSources(),
        acceptsFirstFragment: { $0.target == choice.target && $0.elementID == choice.elementID }) else { return nil }
    return selected
  }
  #endif

  enum PointResolution {
    case hit(NotebookAttentionSelection.Fragment)
    case pending
  }

  /// Missing cut geometry is not empty material. While the canonical worker
  /// prepares it, do not retarget the same contact to an owner underneath.
  static func pointResolution(at point: CGPoint, model: NotebookAppModel, presence: SessionPresence,
    cohort: SceneCompositionCohort?) -> PointResolution? {
    // The installed paper and accepted material share one hit query. Focus
    // does not decide whether an already accepted fragment exists here.
    if presence.mode == .page,
      let id=presence.notebookPageID ?? model.workspace?.selectedPageID,let page=model.pages[id] {
      let box:CGRect?
      #if os(macOS)
      box=readingPaperFrame(model:model,presence:presence)
      #else
      box=model.pagePresentations.hasInstalledGraphics(page)
        ? frame(.init(target:.init(kind:.page,id:id),revision:""),model:model,presence:presence) : nil
      #endif
      guard let box,box.contains(point) else { return nil }
      let local = SpatialPoint(x:(point.x-box.minX)/presence.camera.scale,y:(point.y-box.minY)/presence.camera.scale)
      let graph = model.graphicGraph(page:page)
      let working = model.workingGraphics.filter { $0.surface == .page(page.id) }.map(\.pageElement)
      var pending = false
      let element = pickElement(in:pageInteractionElements(at:local,page:page,graph:graph,
        scale:presence.camera.scale,working:working),graph:graph,erasures:model.elementErasures(on:.page(page.id)),
        appearance:{ model.elementErasureCache.appearance(surface:.page(page.id),id:$0,graphic:$1,layout:$2,size:$3,erasures:$4) },
        scale:presence.camera.scale,viewport:presence.viewport,pending:{ pending = true },
        presentation:{ .init($0,placement:$1) },project:{ ($0.id,graph.node($0.id)?.graphic ?? $0.graphic,local) })
      if pending { return .pending }
      #if os(iOS)
      // Do not reinterpret an unpresented ink plane as blank paper below it.
      if element == nil, !model.pagePresentations.isPresented(page) { return .pending }
      #endif
      return .hit(.init(target:.init(kind:.page,id:page.id),elementID:element?.id,
        region:element.flatMap { graph.resolve($0.id).layout?.frame ?? graph.elementPresentation($0.id)?.frame }
          ?? .init(x:local.x,y:local.y,width:1,height:1),worldOrigin:nil,pageIndex:nil,label:element == nil ? "Место" : "Объект"))
    }
    guard let cohort, var sources = contactSources(model:model,presence:presence,cohort:cohort) else { return nil }
    sources.materialGraph={ model.interactionGraphicGraph(boardID:$0,cohort:cohort) }
    sources.working=model.workingGraphics.filter { value in
      value.surface.kind != .page && (value.publicationCursor.map { cohort.plan.revision < $0 } ?? true)
    }.map { $0.spatialElement(stamp:.init(counter:0,actor:model.actorID)) }
    var pending = false
    let hit = fragment(start:point,end:point,sources:sources,presence:presence,dragged:false,
      pending: { pending = true })
    return pending ? .pending : hit.map(PointResolution.hit)
  }

  /// Resolve the painted contact without freezing pixels or constructing a
  /// shared attention selection. Local authoring does not borrow the scene.
  static func pointContact(at point: CGPoint, model: NotebookAppModel, presence: SessionPresence,
    cohort: SceneCompositionCohort?) -> NotebookAttentionSelection.Fragment? {
    guard case .hit(let hit) = pointResolution(at:point,model:model,presence:presence,cohort:cohort) else { return nil }
    return hit
  }

  static func toolAddress(at point: CGPoint, fragment: NotebookAttentionSelection.Fragment,
    model: NotebookAppModel, presence: SessionPresence) -> (address: NotebookToolAddress, point: SpatialPoint)? {
    if fragment.target.kind == .board {
      return (.init(surface:.board(fragment.target.id),boardID:fragment.target.id,
        worldOrigin:presence.camera.screenToWorld(.init(x:point.x,y:point.y),viewport:presence.viewport),bounds:nil),.zero)
    }
    guard [.page,.cover].contains(fragment.target.kind),
      let rect = frame(.init(target:fragment.target,revision:""),model:model,presence:presence) else { return nil }
    let scale = presence.camera.scale
    return (.init(surface:fragment.target.kind == .page ? .page(fragment.target.id) : .cover(fragment.target.id),
      boardID:presence.boardID,worldOrigin:nil,bounds:.init(x:0,y:0,width:rect.width/scale,height:rect.height/scale)),
      .init(x:(point.x-rect.minX)/scale,y:(point.y-rect.minY)/scale))
  }

  /// Lift an already selected measured body, not a new point selection. The
  /// installed contact query chooses its visible physical surface; raw ink is
  /// above that surface's authored material, so an authored ID is not a veto.
  /// Captured cuts and the current ink revision prevent a hole or stale source
  /// from acquiring a drag. Fresh choices remain with the drawing-tool owner.
  static func selectedInk(at point:CGPoint,model:NotebookAppModel,presence:SessionPresence,
    cohort:SceneCompositionCohort?) -> NotebookSelectedInk.Key? {
    guard !model.selectionSession.isInteractive,!model.selectionSession.ink.isEmpty,
      presence.boardID == model.presence?.boardID,
      let hit=pointContact(at:point,model:model,presence:presence,cohort:cohort) else { return nil }
    let scale=max(presence.camera.scale,0.001)
    let poses=selectedInkPoses(model:model)
    for raw in model.selectionSession.ink.reversed() {
      guard raw.address.target == hit.target,model.selectionAddressIsCurrent(raw.address),
        model.selectionInkRevision(raw.address.surface) == raw.revision else { continue }
      let pose=poses[raw.memberID],local=pose?.frame ?? raw.material.frame
      guard let box=frame(target:raw.address.target,elementID:nil,region:local,
        worldOrigin:raw.address.worldOrigin,pageIndex:nil,model:model,presence:presence,minimumSide:0),
        box.insetBy(dx:-elementHitPadding,dy:-elementHitPadding).contains(point) else { continue }
      if NotebookGraphicGeometry.hitTest(pose?.graphic ?? raw.material.graphic,
        width:local.width,height:local.height,x:(point.x-box.minX)/scale,y:(point.y-box.minY)/scale,
        tolerance:elementHitPadding/scale) { return raw.key }
    }
    return nil
  }

  /// Selection does not invent a second rectangular hit rule. A region owns
  /// its contour; ordinary choices use the same painted contact as a fresh tap.
  static func selectedElement(at point:CGPoint,model:NotebookAppModel,presence:SessionPresence,
    cohort:SceneCompositionCohort?) -> EditableElementReference? {
    guard !model.selectionSession.isInteractive else { return nil }
    if let region=model.selectionSession.region,
      let box=editingFrame(region.reference,model:model,presence:presence),box.width > 0,box.height > 0 {
      let p=CGPoint(x:region.frame.x+(point.x-box.minX)*region.frame.width/box.width,
        y:region.frame.y+(point.y-box.minY)*region.frame.height/box.height)
      let path=CGMutablePath();path.addLines(between:region.polygon.map { CGPoint(x:$0.x,y:$0.y) });path.closeSubpath()
      if path.contains(p,using:.evenOdd) { return region.reference }
    }
    let painted=pointContact(at:point,model:model,presence:presence,cohort:cohort)
    guard let hit=painted,
      let id=hit.elementID,[CollaborationTarget.Kind.page,.board,.cover].contains(hit.target.kind) else { return nil }
    let reference:EditableElementReference = hit.target.kind == .page ? .page(pageID:hit.target.id,elementID:id)
      : .spatial(boardID:hit.target.boardID ?? hit.target.id,elementID:id)
    if model.selectionSession.contains(reference) { return reference }
    let ancestors=model.editingGraphicGraph(reference)?.placement(id)?.ancestors ?? []
    return model.selectionSession.elements.first { selected in
      ancestors.contains(selected.elementID) && model.nativeElementSource(selected)?.target == hit.target
    }
  }

  private static func contactSources(model: NotebookAppModel, presence: SessionPresence,
    cohort: SceneCompositionCohort) -> CaptureSources? {
    guard cohort.isPaintInstalled, cohort.plan.presentations[.board(presence.boardID)] != nil else { return nil }
    var sources = CaptureSources(workset: model.presentedWorkset(cohort: cohort, boardID: presence.boardID, presence: presence),
      workspace: model.presentedWorkspace(cohort: cohort), hierarchy: model.presentedHierarchy(cohort: cohort), ink: cohort.liveData.ink,
      pages: cohort.liveData.pages, documents: cohort.liveData.documents, states: cohort.liveData.states,
      selectedPageID: presence.notebookPageID ?? model.workspace?.selectedPageID,
      erasures: { model.elementErasures(on:$0,fallback:cohort.liveData.ink) },
      appearance: { model.elementErasureCache.appearance(surface:$0,id:$1,graphic:$2,layout:$3,size:$4,erasures:$5) })
    if let focused = presence.focusedItemID, cohort.plan.allowsLive(.item(focused), in: .board(presence.boardID)) {
      if presence.mode == .page, let id = sources.selectedPageID, let page = model.pages[id] {
        #if os(iOS)
        guard model.pagePresentations.isPresented(page) else { return nil }
        #endif
        sources.pages[id] = page
      } else if presence.mode == .document, let document = model.documents[focused], let state = model.documentStates[focused] {
        guard DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: presence.documentPageIndex, scope: .paper) else { return nil }
        sources.documents[focused] = document; sources.states[focused] = state
      }
    }
    return sources
  }

  static func capture(start: CGPoint, end: CGPoint, model: NotebookAppModel, presence: SessionPresence,
    cohort: SceneCompositionCohort, installedInk: [SurfaceID: SpatialInkInstalledSource], itemID: UUID? = nil,
    selectedElements: [EditableElementReference]? = nil, compositeRegion: Bool = false,
    acceptsFirstFragment: (NotebookAttentionSelection.Fragment) -> Bool = { _ in true }) -> NotebookAttentionSelection? {
    guard let sources = contactSources(model:model,presence:presence,cohort:cohort) else { return nil }
    let fragments: [NotebookAttentionSelection.Fragment]
    if let selectedElements {
      guard (1...32).contains(selectedElements.count), Set(selectedElements).count == selectedElements.count,
        selectedElements.allSatisfy({ model.elementCommandDrafts[$0] == nil }), model.selectionSession.manipulation == nil else { return nil }
      var selected: [NotebookAttentionSelection.Fragment] = []
      var graphs: [SurfaceID:NotebookGraphicGraph] = [:]
      for reference in selectedElements {
        let target: CollaborationTarget, id: String, surface: SurfaceID, origin: WorldPoint?
        switch reference {
        case .page(let owner,let elementID):
          guard presence.mode == .page, sources.selectedPageID == owner, let page = sources.pages[owner] else { return nil }
          surface = .page(owner)
          if graphs[surface] == nil { graphs[surface] = page.graphicGraph() }
          target = .init(kind:.page,id:owner); id = elementID; origin = nil
        case .spatial(let boardID,let elementID):
          guard boardID == presence.boardID, model.presentedElement(reference,cohort:cohort) != nil,
            let board = sources.hierarchy.board(boardID), let element = board.element(id:elementID),
            let owner = element.surface.ownerID else { return nil }
          surface = element.surface
          if graphs[surface] == nil { graphs[surface] = board.graphicGraph() }
          target = .init(kind:element.surface.kind == .cover ? .cover : .board,id:owner,
            boardID:element.surface.kind == .cover ? boardID : nil)
          id = elementID; origin = element.worldOrigin
        }
        guard selected.first.map({ $0.target == target }) ?? true,
          let layout = graphs[surface]?.resolve(id).layout else { return nil }
        selected.append(.init(target:target,elementID:id,region:layout.frame,worldOrigin:origin,pageIndex:nil,label:"Объект схемы"))
      }
      fragments = selected
    } else {
      fragments = itemID.map { id in
        fragment(start:start,end:end,sources:sources,presence:presence,ownerID:id,dragged:true).map { [$0] } ?? []
      } ?? (compositeRegion && presence.mode == .board
        ? fragment(start:start,end:end,sources:sources,presence:presence,dragged:true).map { [$0] } ?? []
        : Self.fragments(start:start,end:end,sources:sources,presence:presence))
    }
    // A contact owner can decline this resolved source before borrowing or
    // copying pixels. In particular, a document link cannot become an element
    // drag, so touch-down must not snapshot the whole visible paper first.
    guard let first = fragments.first, acceptsFirstFragment(first) else { return nil }
    for fragment in fragments where fragment.target.kind == .document {
      guard let document = sources.documents[fragment.target.id], let state = sources.states[fragment.target.id],
        let page = fragment.pageIndex,
        DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: page,
          scope: .region(fragment.region)) else { return nil }
    }
    for fragment in fragments where fragment.elementID == nil && fragment.target.kind == .board {
      let boards = sources.hierarchy.descendantBoardIDs(including: fragment.target.id)
      guard preservesPresentedPlacementPixels(cohort: cohort, hierarchy: sources.hierarchy,
        boards: boards, model: model, presence: presence) else { return nil }
    }
    // Readiness is local to the pixels selected by this contact. A ready cache
    // entry elsewhere is not proof that this source was installed; a pending
    // neighbour outside this region must not block attention to a ready item.
    var sampled = Set<SceneSourceAddress>()
    for fragment in fragments where [.board, .cover].contains(fragment.target.kind) {
      let boardID = fragment.target.boardID ?? fragment.target.id
      if let id = fragment.elementID {
        let plane: SceneCompositionPlane = fragment.target.kind == .cover
          ? .cover(boardID: boardID, itemID: fragment.target.id) : .board(boardID)
        sampled.insert(.init(plane: plane, elementID: id))
      } else {
        let boards = fragment.target.kind == .board
          ? sources.hierarchy.descendantBoardIDs(including: boardID) : [boardID]
        for address in cohort.sourceReceipts.keys where boards.contains(address.plane.boardID) {
          guard fragment.target.kind == .board || address.plane.coverID == fragment.target.id,
            let element = sources.hierarchy.board(address.plane.boardID)?.element(id:address.elementID),
            intersects(fragment, element: element, boardID: address.plane.boardID, workset: sources.workset) else { continue }
          sampled.insert(address)
        }
      }
    }
    for address in sampled {
      // A removed live host contributes no pixels. Its old retained hash and
      // neighboring order edges are removed by the reference basis at sealing.
      guard let element = sources.hierarchy.board(address.plane.boardID)?.element(id:address.elementID) else { continue }
      if element.kind != .nativeText && element.kind != .graphic {
        guard cohort.hasInstalledPixels(for: address), let receipt = cohort.sourceReceipts[address], receipt.hasCurrentPixels,
          SceneRasterSource.agent(receipt.demand.source) == .agent(agentElementSnapshotSource(element)) else { return nil }
      }
    }
    #if os(iOS)
    let sceneSources = NotebookWorkspacePresentedSources(workspace: sources.workspace, hierarchy: sources.hierarchy,
      staticInk: cohort.liveData.ink.stamp, installedInk: installedInk.mapValues(\.journalRevision))
    var coverSources: [UUID: NotebookCoverPresentedSources] = [:]
    for fragment in fragments where fragment.target.kind == .cover && fragment.elementID == nil {
      guard let item = sources.workset.items.first(where: { $0.id == fragment.target.id }), item.item.kind != .board else { continue }
      let boardID = fragment.target.boardID ?? presence.boardID
      coverSources[fragment.id] = .init(boardID: boardID,
        revision: .init(item: item.item, geometry: item.geometry,
          elements: model.presentedCoverElements(cohort: cohort, boardID: boardID, itemID: item.id), journal: model.spatialInk),
        installedInkRevision: installedInk[.cover(item.id)]?.journalRevision)
    }
    #endif
    let visuals = NotebookFrozenVisualSources.capture(fragments: fragments, hierarchy: sources.hierarchy,
      pages: sources.pages, documents: sources.documents, states: sources.states,
      elementErasures: { model.elementErasures(on: $0, fallback: sources.ink)[$1] ?? [] },
      installedSources: cohort.sourceRasters, capturesLivePrograms: true,
      liveSourceAddresses: Set(sampled.filter { cohort.plan.allowsLive(.element($0.elementID), in: $0.plane) }),
      captureSceneRegion: { [weak model] fragment in
        #if os(iOS)
        guard let model else { return nil }
        if fragment.target.kind == .cover {
          guard let expected = coverSources[fragment.id] else { return nil }
          return try model.coverPresentations.capture(itemID: fragment.target.id, expected: expected,
            region: fragment.region, resources: .shared)
        }
        return try model.workspacePresentations.capture(fragment: fragment, expectedSources: sceneSources, resources: .shared)
        #else
        return nil
        #endif
      })
    var requiredInk = Set<SurfaceID>()
    for fragment in fragments where fragment.elementID == nil {
      if fragment.target.kind == .board {
        let descendants = sources.hierarchy.descendantBoardIDs(including: fragment.target.id)
        for id in cohort.plan.inkBoardIDs where descendants.contains(id) { requiredInk.insert(.board(id)) }
        for owner in cohort.plan.liveOwners where descendants.contains(owner.plane.boardID) {
          if case .item(let id) = owner.id { requiredInk.insert(.cover(id)) }
        }
      } else if fragment.target.kind == .cover,
        cohort.plan.allowsLive(.item(fragment.target.id), in: .board(fragment.target.boardID ?? presence.boardID)) {
        requiredInk.insert(.cover(fragment.target.id))
      }
    }
    // Only already admitted native text can contribute its accepted draft to
    // this frozen scene. Retain that command, not the model's future tail.
    var accepted:[EditableElementReference:Task<NotebookElementCommandResult?,Never>]=[:]
    for (ref,draft) in model.elementCommandDrafts where draft.graphic == nil && !draft.source.isGroup {
      guard case .spatial(let boardID,let id)=ref,
        let element=cohort.frame.index.element(id:id,boardID:boardID),element.kind == .nativeText,
        let command=model.elementCommandSources[ref] else { continue }
      let plane:SceneCompositionPlane=element.surface.kind == .cover
        ? .cover(boardID:boardID,itemID:element.surface.ownerID!) : .board(boardID)
      let relevant=fragments.contains { fragment in
        guard fragment.elementID == nil || fragment.elementID == id else { return false }
        if fragment.target.kind == .cover { return element.surface == .cover(fragment.target.id) }
        return fragment.target.kind == .board && sources.hierarchy.descendantBoardIDs(including:fragment.target.id).contains(boardID)
      }
      if relevant && cohort.plan.allowsLive(.element(id),in:plane) { accepted[ref]=command.task }
    }
    var placements: [UUID: NotebookAttentionSelection.AcceptedPlacement] = [:]
    for (id, command) in model.itemPlacementCommands {
      let boardID = command.boardID
      guard cohort.plan.allowsLive(.item(id), in: .board(boardID)),
        sources.hierarchy.board(boardID)?.placements.contains(where: { $0.id == id }) == true else { continue }
      let relevant = fragments.contains { fragment in
        if fragment.target.kind == .cover { return fragment.target.id == id }
        return fragment.target.kind == .board
          && sources.hierarchy.descendantBoardIDs(including: fragment.target.id).contains(boardID)
      }
      if relevant { placements[id] = .init(boardID: boardID, task: command.task) }
    }
    return .init(fragments: fragments, workspace: sources.workspace, hierarchy: sources.hierarchy, ink: sources.ink,
      pages: sources.pages, documents: sources.documents, states: sources.states, visuals: visuals,
      referenceIdentities: cohort.liveData.referenceIdentities,
      installedInk: installedInk.filter { requiredInk.contains($0.key) }, requiredInk: requiredInk,
      referenceBasis: cohort.liveData.referenceBasis,acceptedElements:accepted,acceptedPlacements:placements)
  }

  private static func intersects(_ fragment: NotebookAttentionSelection.Fragment,
    element: SpatialElement, boardID: UUID, workset: WorkspaceSceneWorkset) -> Bool {
    let region = fragment.region
    let selected = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
    if fragment.target.kind == .cover {
      return selected.intersects(CGRect(x: element.frame.x, y: element.frame.y,
        width: element.frame.width, height: element.frame.height))
    }
    // A nested portal has its own camera and clipping. Until its projection is
    // resolved, retain its finite admitted dependency instead of omitting paint.
    guard boardID == fragment.target.id else { return true }
    let origin: WorldPoint
    if element.surface.kind == .cover {
      guard let owner = workset.items.first(where: { $0.id == element.surface.ownerID }) else { return true }
      origin = owner.center.offsetBy(x: -owner.geometry.width / 2, y: -owner.geometry.height / 2)
    } else { origin = element.worldOrigin ?? .zero }
    let delta = (fragment.worldOrigin ?? .zero).delta(to: origin)
    return selected.intersects(CGRect(x: delta.x + element.frame.x, y: delta.y + element.frame.y,
      width: element.frame.width, height: element.frame.height))
  }

  /// Joining or leaving a stack changes its fan without authoring peer poses.
  /// Current live bodies never wait for a tile; a whole-area contact must also
  /// describe their actual fan and every retained passive pixel.
  private static func preservesPresentedPlacementPixels(cohort: SceneCompositionCohort,
    hierarchy: BoardHierarchy, boards: Set<UUID>, model: NotebookAppModel,
    presence: SessionPresence) -> Bool {
    for id in boards {
      guard let original = cohort.frame.index.capturedHierarchy.board(id), let shown = hierarchy.board(id) else { continue }
      for item in original.itemIDs where !cohort.plan.allowsLive(.item(item), in: .board(id)) {
        if let a = original.placement(of: item), let b = shown.placement(of: item) {
          guard a.center == b.center, a.zIndex == b.zIndex else { return false }
        } else if let a = original.stack(containing: item), let b = shown.stack(containing: item) {
          guard a.id == b.id, a.center == b.center, a.zIndex == b.zIndex, a.itemIDs == b.itemIDs else { return false }
        } else { return false }
      }
      guard let planePresence = id == presence.boardID ? presence : cohort.frame.presences[id] else { continue }
      let current = model.presentedWorkset(cohort: cohort, boardID: id, presence: planePresence)
      for admitted in cohort.frame.workset(boardID: id).items where cohort.plan.allowsLive(.item(admitted.id), in: .board(id)) {
        let projected: RenderedWorkspaceItem?
        if let pose = shown.placement(of: admitted.id) {
          projected = WorkspaceSceneProjection.renderedItem(admitted.item, geometry: admitted.geometry,
            center: pose.center, zIndex: Double(pose.zIndex), stack: nil, presence: planePresence)
        } else if let stack = shown.stack(containing: admitted.id), let offset = stack.itemIDs.firstIndex(of: admitted.id) {
          projected = WorkspaceSceneProjection.renderedItem(admitted.item, geometry: admitted.geometry,
            center: stack.center, zIndex: Double(stack.zIndex) + Double(offset) / 100, stack: stack, presence: planePresence)
        } else { projected = nil }
        let body = current.items.first { $0.id == admitted.id }
        guard projected?.center == body?.center, projected?.zIndex == body?.zIndex,
          projected?.stackID == body?.stackID else { return false }
      }
    }
    return true
  }

  private static func fragments(start: CGPoint, end: CGPoint, sources: CaptureSources, presence: SessionPresence) -> [NotebookAttentionSelection.Fragment] {
    let dragged = hypot(end.x - start.x, end.y - start.y) > 8
    if dragged, presence.mode == .page || presence.mode == .document {
      // Open paper owns the region even when the finger crosses its edge.
      // Requiring full containment would silently select the board behind it.
      guard let focused = presence.focusedItemID,
        let item = sources.workset.items.first(where: { $0.id == focused }) else { return [] }
      let box = item.geometry.screenFrame(center: item.center, camera: presence.camera, viewport: presence.viewport)
      let selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
        width: abs(end.x - start.x), height: abs(end.y - start.y))
      let clipped = selection.intersection(CGRect(x: box.x, y: box.y, width: box.width, height: box.height))
      guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return [] }
      return fragment(start: .init(x: clipped.minX, y: clipped.minY), end: .init(x: clipped.maxX, y: clipped.maxY),
        sources: sources, presence: presence, ownerID: focused, dragged: true).map { [$0] } ?? []
    }
    guard presence.mode == .board, dragged else {
      return fragment(start: start, end: end, sources: sources, presence: presence, dragged: dragged).map { [$0] } ?? []
    }
    let selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    var result = fragment(start: start, end: end, sources: sources, presence: presence, dragged: dragged).map { [$0] } ?? []
    for item in sources.workset.items {
      let box = item.geometry.screenFrame(center: item.center, camera: presence.camera, viewport: presence.viewport)
      let intersection = selection.intersection(CGRect(x: box.x, y: box.y, width: box.width, height: box.height))
      guard !intersection.isNull, intersection.width > 0, intersection.height > 0,
        !result.contains(where: { $0.target.id == item.id }), result.count < 32 else { continue }
      if let reference = fragment(start: .init(x: intersection.minX, y: intersection.minY),
        end: .init(x: intersection.maxX, y: intersection.maxY), sources: sources, presence: presence, ownerID: item.id, dragged: dragged) {
        result.append(reference)
      }
    }
    return result
  }

  private static func fragment(start: CGPoint, end: CGPoint, sources: CaptureSources, presence: SessionPresence,
    ownerID: UUID? = nil, dragged: Bool, pending: () -> Void = {}) -> NotebookAttentionSelection.Fragment? {
    var unresolved = false
    let awaitingAppearance = { unresolved = true; pending() }
    guard let board = sources.hierarchy.board(presence.boardID) else { return nil }
    // Clipping an area to a tiny owner intersection never turns the original
    // drag into a tap that authorizes the whole element or physical cover.
    let width = abs(end.x - start.x), height = abs(end.y - start.y)
    guard !dragged || (width > 0 && height > 0) else { return nil }
    let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
      width: dragged ? width : max(1, width), height: dragged ? height : max(1, height))
    let admitted = sources.workset
    let items = ownerID.map { id in admitted.items.first(where: { $0.id == id }).map { [$0] } ?? [] } ?? admitted.items
    var target = CollaborationTarget(kind:.board,id:presence.boardID)
    var region: PageRect
    var origin: WorldPoint?
    var elementID: String?
    var pageIndex: Int?
    if let item = items.filter({ item in
      if let ownerID { return item.id == ownerID }
      let frame = item.geometry.screenFrame(center:item.center,camera:presence.camera,viewport:presence.viewport)
      return CGRect(x:frame.x,y:frame.y,width:frame.width,height:frame.height).contains(rect)
    }).max(by: { WorkspaceSceneProjection.isPaintedBelow($0, $1, in: presence) }) {
      let box = item.geometry.screenFrame(center:item.center,camera:presence.camera,viewport:presence.viewport)
      region = .init(x:max(0,(rect.minX-box.x)/presence.camera.scale),y:max(0,(rect.minY-box.y)/presence.camera.scale),
        width:rect.width/presence.camera.scale,height:rect.height/presence.camera.scale)
      if presence.focusedItemID == item.id && presence.mode == .page, let pageID = sources.selectedPageID {
        target = .init(kind:.page,id:pageID)
        let graph = sources.pages[pageID]?.graphicGraph()
        if !dragged, let page = sources.pages[pageID], let graph,
          let element = pickElement(in: pageInteractionElements(at:.init(x:region.x,y:region.y),
            page:page,graph:graph,scale:presence.camera.scale), graph: graph, erasures:sources.erasures(.page(pageID)),
            appearance: { sources.appearance(.page(pageID), $0, $1, $2, $3, $4) }, scale: presence.camera.scale, viewport: presence.viewport,pending:awaitingAppearance,presentation:{ .init($0,placement:$1) },
            project: { ($0.id, $0.graphic, .init(x:region.x,y:region.y)) }) {
          elementID = element.id; region = graph.resolve(element.id).layout?.frame ?? graph.placement(element.id).map { NotebookElementPresentation(element,placement:$0).frame } ?? NotebookTextTypography.frame(element)
        }
      } else if presence.focusedItemID == item.id && presence.mode == .document,
        let document = sources.documents[item.id] {
        target = .init(kind:.document,id:item.id); pageIndex = presence.documentPageIndex
        if !dragged, let block = DocumentRenderRegistry.shared.regions(document: document).first(where: {
          $0.pageIndex == pageIndex && CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height)
            .contains(CGPoint(x: region.x, y: region.y))
        }) {
          elementID = block.id; region = block.frame
        }
      } else {
        target = .init(kind:.cover,id:item.id,boardID:presence.boardID)
        if !dragged {
          let graph = sources.materialGraph?(presence.boardID) ?? board.graphicGraph()
          let working=sources.working.filter { $0.surface == .cover(item.id) },ids=Set(working.map(\.id))
          let elements=board.elements.filter { $0.surface == .cover(item.id) && !ids.contains($0.id) }+working
          if let element = pickElement(in: elements, graph: graph, erasures:sources.erasures(.cover(item.id)),
            appearance: { sources.appearance(.cover(item.id), $0, $1, $2, $3, $4) },
            scale: presence.camera.scale, viewport: presence.viewport,pending:awaitingAppearance,presentation:{ .init($0,placement:$1) }, project: {
              ($0.id, graph.node($0.id)?.graphic ?? $0.graphic,
                .init(x:region.x,y:region.y))
            }) {
            elementID = element.id
            region = graph.resolve(element.id).layout?.frame ?? graph.placement(element.id).map { NotebookElementPresentation(element,placement:$0).frame } ?? NotebookTextTypography.frame(element)
          }
          if elementID == nil { region = .init(x:0,y:0,width:item.geometry.width,height:item.geometry.height) }
        }
      }
    } else {
      origin = presence.camera.screenToWorld(.init(x:rect.minX,y:rect.minY),viewport:presence.viewport)
      region = .init(x:0,y:0,width:rect.width/presence.camera.scale,height:rect.height/presence.camera.scale)
      if !dragged, let pointOrigin = origin {
        let graph = sources.materialGraph?(presence.boardID) ?? board.graphicGraph()
        let working=sources.working.filter { $0.surface == .board(presence.boardID) },ids=Set(working.map(\.id))
        let elements=admitted.elements.filter { $0.surface == .board(presence.boardID) && !ids.contains($0.id) }+working
        if let element = pickElement(in: elements, graph: graph, erasures:sources.erasures(.board(presence.boardID)),
            appearance: { sources.appearance(.board(presence.boardID), $0, $1, $2, $3, $4) },
          scale: presence.camera.scale, viewport: presence.viewport,pending:awaitingAppearance,presentation:{ .init($0,placement:$1) }, project: {
            ($0.id, graph.node($0.id)?.graphic ?? $0.graphic,
              (graph.placement($0.id)?.origin ?? $0.worldOrigin ?? .zero).delta(to: pointOrigin))
          }) {
          elementID = element.id
          region = graph.resolve(element.id).layout?.frame ?? graph.placement(element.id).map { NotebookElementPresentation(element,placement:$0).frame } ?? NotebookTextTypography.frame(element)
          origin = graph.placement(element.id)?.origin ?? element.worldOrigin ?? .zero
        }
      }
    }
    guard !unresolved else { return nil }
    return .init(target:target,elementID:elementID,region:region,worldOrigin:origin,pageIndex:pageIndex,
      label: dragged ? "Область" : elementID == nil ? "Место" : "Объект")
  }

  /// The retained page index is the broad-phase owner for taps as well as
  /// lasso and erasing. Exact picking below still owns paint order and holes.
  static func pageInteractionElements(at point:SpatialPoint,page:PageDocument,
    graph:NotebookGraphicGraph,scale:Double,working:[AgentElement] = [])->[AgentElement] {
    let radius=elementHitPadding/max(0.001,scale)
    let hit=graph.visiblePageGraphics(page.id,
      in:.init(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2))
    let ids = Set(hit.layouts.keys).union(hit.placements.keys)
    guard !working.isEmpty else { return page.interactionElements(ids:ids) }
    let replaced = Set(working.map(\.id))
    return page.interactionElements(ids:ids.subtracting(replaced)) + working.filter { ids.contains($0.id) }
  }

  /// Paint wins over a hollow interior, then the smallest enclosing figure.
  /// The same pick serves tap, direct drag and the resulting shared reference.
  static func pickElement<Element>(in elements: [Element], graph: NotebookGraphicGraph, erasures: [String: [InkElementErasure]] = [:],
    appearance: (String, NotebookGraphic?, NotebookGraphicLayout?, CGSize, [InkElementErasure]) -> NotebookElementAppearance? = { _,_,_,_,_ in nil }, scale: Double,
    viewport: SpatialPoint, pending: () -> Void = {}, presentation:(Element,NotebookElementPlacement) -> NotebookElementPresentation,
    project: (Element) -> (String, NotebookGraphic?, SpatialPoint)) -> Element? {
    var interior: (Element, Double)?
    let tolerance = elementHitPadding / max(0.001, scale)
    for element in elements.reversed() {
      let (id, graphic, point) = project(element)
      if graphic == nil {
        guard let placement=graph.placement(id),graph.source(id)?.isGroup != true else { continue }
        let body=presentation(element,placement)
        let local=CGPoint(x:point.x,y:point.y).applying(placement.transform.inverted())
        if let cuts=erasures[id],!cuts.isEmpty {
          let inverseScale=NotebookElementPresentation.maximumScale(placement.transform.inverted())
          guard body.localBounds.insetBy(dx:-tolerance*inverseScale,dy:-tolerance*inverseScale).contains(local) else { continue }
          guard let prepared=appearance(id,nil,nil,body.bodySize,cuts) else { pending(); return nil }
          if prepared.contains(.init(x:local.x,y:local.y),tolerance:tolerance*inverseScale) { return element }
        } else if body.localBounds.contains(local) { return element }
        continue
      }
      guard let graphic,let layout=graph.resolve(id).layout else { continue }
      if let cuts = erasures[id], !cuts.isEmpty {
        let box = layout.frame
        guard CGRect(x:box.x,y:box.y,width:box.width,height:box.height)
          .insetBy(dx:-tolerance,dy:-tolerance).contains(CGPoint(x:point.x,y:point.y)) else { continue }
        guard let prepared = appearance(id,graphic,layout,.init(width:box.width,height:box.height),cuts) else { pending(); return nil }
        if prepared.contains(.init(x:point.x-box.x,y:point.y-box.y),tolerance:tolerance) { return element }
        // A cutout is not an intact hollow figure: its empty old interior may
        // not steal selection from the paper or surviving fragments below it.
        continue
      }
      let local = SpatialPoint(x:point.x-layout.frame.x,y:point.y-layout.frame.y)
      if layout.hitTest(local,graphic:graphic,tolerance:tolerance) { return element }
      let width = layout.frame.width, height = layout.frame.height
      guard NotebookGraphicGeometry.containsInterior(graphic,width:width,height:height,x:local.x,y:local.y) else { continue }
      let area = width*height
      if interior == nil || area < interior!.1 { interior = (element,area) }
    }
    return interior?.0
  }

}
