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
      guard let element = model.pages[reference.target.id]?.elements.first(where: { $0.id == id }) else { return nil }
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
    let scale = presence.camera.scale
    let origin: CGPoint
    if target.address.surface.kind == .board {
      guard target.address.boardID == presence.boardID else { return nil }
      let point = presence.camera.worldToScreen(target.address.worldOrigin ?? .zero,viewport:presence.viewport)
      origin = .init(x:point.x,y:point.y)
    } else {
      guard let rect = frame(.init(target:target.address.target,revision:""),model:model,presence:presence) else { return nil }
      origin = rect.origin
    }
    return .init(x:origin.x+target.frame.x*scale,y:origin.y+target.frame.y*scale,
      width:target.frame.width*scale,height:target.frame.height*scale)
  }

  static func editingFrame(_ reference: EditableElementReference, model: NotebookAppModel, presence: SessionPresence,
    layout: NotebookGraphicLayout? = nil) -> CGRect? {
    let target: CollaborationTarget, id: String
    switch reference {
    case .page(let pageID, let elementID): target = .init(kind: .page, id: pageID); id = elementID
    case .spatial(let boardID, let elementID):
      guard boardID == presence.boardID,
        let cohort = model.compositionTiles.published,
        let element = model.presentedElement(reference, cohort: cohort) ?? cohort.frame.index.element(id:elementID,boardID:boardID), let owner = element.surface.ownerID else { return nil }
      target = .init(kind: element.surface.kind == .cover ? .cover : .board, id: owner, boardID: boardID); id = elementID
    }
    return frame(target: target, elementID: id, region: nil, worldOrigin: nil, pageIndex: nil, model: model, presence: presence, minimumSide: 0, graphicLayout:layout)
  }

  private static func frame(target: CollaborationTarget, elementID: String?, region: PageRect?,
    worldOrigin: WorldPoint?, pageIndex: Int?, model: NotebookAppModel, presence: SessionPresence, minimumSide: Double = 8,
    graphicLayout: NotebookGraphicLayout? = nil) -> CGRect? {
    guard let workspace = model.workspace, let cohort = model.compositionTiles.published else { return nil }
    let index = cohort.frame.index
    var local = region ?? PageRect(x:0,y:0,width:1,height:1)
    if target.kind == .board {
      guard target.id == presence.boardID else { return nil }
      var origin = worldOrigin ?? .zero
      if let id = elementID {
        guard let element = model.presentedElement(.spatial(boardID: presence.boardID, elementID: id), cohort: cohort) ?? index.element(id:id,boardID:presence.boardID),
          element.surface == .board(target.id) else { return nil }
        local = model.elementPresentationFrame(.spatial(boardID:presence.boardID,elementID:id),
          fallback:.init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height))
        if element.graphic != nil {
          guard let layout = graphicLayout ?? model.graphicLayout(.spatial(boardID:presence.boardID,elementID:id)) else { return nil }
          local = layout.frame;origin = layout.origin
        } else { origin = element.worldOrigin ?? .zero }
      }
      let top = presence.camera.worldToScreen(origin.offsetBy(x:local.x,y:local.y),viewport:presence.viewport)
      return .init(x:top.x,y:top.y,width:max(minimumSide,local.width * presence.camera.scale),height:max(minimumSide,local.height * presence.camera.scale))
    }
    let itemID: UUID
    if target.kind == .page {
      guard let ownerID = model.notebookPageOwner(target.id) ?? index.pageOwner(pageID: target.id),
        workspace.selectedPageID == target.id, presence.mode == .page else { return nil }
      itemID = ownerID
      if let id = elementID {
        guard let element = model.pages[target.id]?.elements.first(where: { $0.id == id }) else { return nil }
        local = model.elementPresentationFrame(.page(pageID:target.id,elementID:id),fallback:element.frame)
        if element.graphic != nil {
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
          guard let element = model.presentedElement(.spatial(boardID: presence.boardID, elementID: id), cohort: cohort),
            element.surface == .cover(itemID) else { return nil }
          local = model.elementPresentationFrame(.spatial(boardID:presence.boardID,elementID:id),
            fallback:.init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height))
          if element.graphic != nil {
            guard let layout = graphicLayout ?? model.graphicLayout(.spatial(boardID:presence.boardID,elementID:id)) else { return nil }
            local = layout.frame
          }
        }
      } else { return nil }
    }
    guard let rendered = model.presentedItem(id: itemID, cohort: cohort, presence: presence) else { return nil }
    let box = rendered.geometry.screenFrame(center:rendered.center,camera:presence.camera,viewport:presence.viewport)
    if region == nil && elementID == nil { local = .init(x:0,y:0,width:rendered.geometry.width,height:rendered.geometry.height) }
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

  /// Resolve the painted contact without freezing pixels or constructing a
  /// shared attention selection. Local authoring does not borrow the scene.
  static func textContact(at point: CGPoint, model: NotebookAppModel, presence: SessionPresence,
    cohort: SceneCompositionCohort) -> NotebookAttentionSelection.Fragment? {
    guard let sources = contactSources(model:model,presence:presence,cohort:cohort) else { return nil }
    return fragment(start:point,end:point,sources:sources,presence:presence,dragged:false)
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
    selectedElements: [EditableElementReference]? = nil,
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
            let board = sources.hierarchy.board(boardID), let element = board.elements.first(where: { $0.id == elementID }),
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
      } ?? Self.fragments(start:start,end:end,sources:sources,presence:presence)
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
            let element = sources.hierarchy.board(address.plane.boardID)?.elements.first(where: { $0.id == address.elementID }),
            intersects(fragment, element: element, boardID: address.plane.boardID, workset: sources.workset) else { continue }
          sampled.insert(address)
        }
      }
    }
    for address in sampled {
      // A removed live host contributes no pixels. Its old retained hash and
      // neighboring order edges are removed by the reference basis at sealing.
      guard let element = sources.hierarchy.board(address.plane.boardID)?.elements.first(where: { $0.id == address.elementID }) else { continue }
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
    return .init(fragments: fragments, workspace: sources.workspace, hierarchy: sources.hierarchy, ink: sources.ink,
      pages: sources.pages, documents: sources.documents, states: sources.states, visuals: visuals,
      referenceIdentities: cohort.liveData.referenceIdentities,
      installedInk: installedInk.filter { requiredInk.contains($0.key) }, requiredInk: requiredInk,
      referenceBasis: cohort.liveData.referenceBasis)
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
    ownerID: UUID? = nil, dragged: Bool) -> NotebookAttentionSelection.Fragment? {
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
          let element = pickElement(in: page.elements, graph: graph, erasures:sources.erasures(.page(pageID)),
            appearance: { sources.appearance(.page(pageID), $0, $1, $2, $3, $4) }, scale: presence.camera.scale, viewport: presence.viewport,
            project: { ($0.id, NotebookTextTypography.frame($0), $0.graphic, .init(x:region.x,y:region.y)) }) {
          elementID = element.id; region = graph.resolve(element.id).layout?.frame ?? NotebookTextTypography.frame(element)
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
          let graph = board.graphicGraph()
          if let element = pickElement(in: board.elements.filter { $0.surface == .cover(item.id) }, graph: graph, erasures:sources.erasures(.cover(item.id)),
            appearance: { sources.appearance(.cover(item.id), $0, $1, $2, $3, $4) },
            scale: presence.camera.scale, viewport: presence.viewport, project: {
              ($0.id, NotebookTextTypography.frame($0), $0.graphic,
                .init(x:region.x,y:region.y))
            }) {
            elementID = element.id
            region = graph.resolve(element.id).layout?.frame ?? NotebookTextTypography.frame(element)
          }
          if elementID == nil { region = .init(x:0,y:0,width:item.geometry.width,height:item.geometry.height) }
        }
      }
    } else {
      origin = presence.camera.screenToWorld(.init(x:rect.minX,y:rect.minY),viewport:presence.viewport)
      region = .init(x:0,y:0,width:rect.width/presence.camera.scale,height:rect.height/presence.camera.scale)
      if !dragged, let pointOrigin = origin {
        let graph = board.graphicGraph()
        if let element = pickElement(in: admitted.elements.filter { $0.surface == .board(presence.boardID) }, graph: graph, erasures:sources.erasures(.board(presence.boardID)),
            appearance: { sources.appearance(.board(presence.boardID), $0, $1, $2, $3, $4) },
          scale: presence.camera.scale, viewport: presence.viewport, project: {
            ($0.id, NotebookTextTypography.frame($0), $0.graphic,
              ($0.worldOrigin ?? .zero).delta(to: pointOrigin))
          }) {
          elementID = element.id
          region = graph.resolve(element.id).layout?.frame ?? NotebookTextTypography.frame(element)
          origin = element.worldOrigin ?? .zero
        }
      }
    }
    return .init(target:target,elementID:elementID,region:region,worldOrigin:origin,pageIndex:pageIndex,
      label: dragged ? "Область" : elementID == nil ? "Место" : "Объект")
  }

  /// Paint wins over a hollow interior, then the smallest enclosing figure.
  /// The same pick serves tap, direct drag and the resulting shared reference.
  static func pickElement<Element>(in elements: [Element], graph: NotebookGraphicGraph, erasures: [String: [InkElementErasure]] = [:],
    appearance: (String, NotebookGraphic?, NotebookGraphicLayout?, CGSize, [InkElementErasure]) -> NotebookElementAppearance? = { _,_,_,_,_ in nil }, scale: Double,
    viewport: SpatialPoint, project: (Element) -> (String, PageRect, NotebookGraphic?, SpatialPoint)) -> Element? {
    var interior: (Element, Double)?
    let tolerance = elementHitPadding / max(0.001, scale)
    for element in elements.reversed() {
      let (id, frame, graphic, point) = project(element)
      if let cuts = erasures[id], !cuts.isEmpty {
        let layout = graphic == nil ? nil : graph.resolve(id).layout
        if graphic != nil && layout == nil { continue }
        let box = layout?.frame ?? frame
        guard let prepared = appearance(id,graphic,layout,.init(width:box.width,height:box.height),cuts) else { continue }
        if prepared.contains(.init(x:point.x-box.x,y:point.y-box.y),tolerance:tolerance) { return element }
        // A cutout is not an intact hollow figure: its empty old interior may
        // not steal selection from the paper or surviving fragments below it.
        continue
      }
      guard let graphic else {
        if point.x >= frame.x, point.x <= frame.x+frame.width, point.y >= frame.y, point.y <= frame.y+frame.height { return element }
        continue
      }
      guard let layout = graph.resolve(id).layout else { continue }
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
