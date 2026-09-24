import AppKit
import NotebookCore
import SwiftUI

/// Desktop composition uses the same prepared source bands and live materials
/// as iPad. Only navigation and pointer input differ; there is no image mirror.
struct NotebookMacCanvas: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.displayScale) private var displayScale
  @State private var pageResolution = NotebookReferencePageResolution()
  @Binding var documentLayout: DocumentPageLayout?

  private struct Preparation: Equatable {
    let presence: SessionPresence
    let generation: UInt64
    let publication: UInt64
    let cursor: UInt64?
    let permits: Bool
    let refinesDetails: Bool
    let selection: NotebookSelectionSession.Target?
    let groupPoses: [SceneCompositionPlane:[String:NotebookElementPlacement.Source]]
  }

  var body: some View {
    GeometryReader { geometry in
      if let stored = model.presence {
        let viewport = SpatialPoint(x: max(1, geometry.size.width), y: max(1, geometry.size.height))
        let adapted = stored.adapted(to: viewport, geometry: model.itemGeometry(stored.focusedItemID))
        let presence = adapted.replacingCamera(model.macConstrainReading(adapted.camera, presence: adapted))
        let pins = pinned(presence)
        let frame = model.sceneIndex.map { WorkspaceSceneFrame(index: $0, presence: presence, portalCamera: model.scenePortalCamera, pinned: pins) }
        let cohort = model.compositionTiles.published.flatMap { $0.plan.rootBoardID == presence.boardID ? $0 : nil }
        let workset = cohort.map { model.presentedWorkset(cohort: $0, boardID: presence.boardID, presence: presence) } ?? .empty
        let request = Preparation(presence: presence, generation: model.sceneIndexGeneration,
          publication: model.scenePublicationGeneration, cursor: model.workspaceHeader?.cursor,
          permits: model.permitsScenePreparation, refinesDetails: model.presencePhase == .settled, selection: model.selectionSession.target,groupPoses:model.compositionGroupPoses)
        ZStack {
          if presence.mode == .page || presence.mode == .document {
            Color(red: 0.90, green: 0.91, blue: 0.90)
          } else { SpatialBoardGrid(camera: presence.camera) }
          MacCanvasNavigation(model: model)
          if presence.mode == .page || presence.mode == .document {
            MacReadingSurface(presence: presence, documentLayout: $documentLayout)
          } else if let cohort {
            elements(workset.elements, presence: presence, cohort: cohort)
            SpatialInkSurfaceView(surface: .board(presence.boardID), journal: cohort.liveData.ink,
              camera: presence.camera, viewport: viewport).allowsHitTesting(false)
            items(workset.items, presence: presence, cohort: cohort)
          } else { ProgressView("Подготовка пространства…") }
          MacMaterialInput(model: model, presence: presence, cohort: cohort)
          if let reference = model.selectionSession.editingElement,
            let rect = NotebookAttentionProjection.editingFrame(reference, model: model, presence: presence) {
            MacElementControls(reference: reference, frame: rect, scale: presence.camera.scale)
          }
          if model.selectionSession.elements.count > 1 {
            VStack { HStack {
              Button("Сгруппировать") { model.groupSelectedElements() }.disabled(!model.canGroupSelectedElements)
              Button("Снять выделение") { model.clearSelection() }
            }.padding(8).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8));Spacer() }.padding()
          }
          if let cue = model.actionCue {
            Text(cue).padding(12).background(.regularMaterial, in: Capsule()).allowsHitTesting(false)
          }
        }
        .frame(width: viewport.x, height: viewport.y).clipped()
        .environment(\.sceneComposition, .init(cohort))
        .environment(\.workspaceSceneFrame, cohort?.frame)
        .task(id: request) {
          guard presence.mode != .page && presence.mode != .document else {
            model.compositionTiles.cancelPreparation(); return
          }
          model.prepareComposition(presence: presence, frame: frame, pinned: pins,
            displayScale: displayScale, installedItemOwners: [:])
        }
        .onChange(of: viewport, initial: true) { _, value in
          guard let p = model.presence, p.viewport != value else { return }
          let adapted = p.adapted(to: value, geometry: model.itemGeometry(p.focusedItemID))
          model.updatePresence(adapted.replacingCamera(model.macConstrainReading(adapted.camera, presence: adapted)), settled: true)
        }
        .onDisappear { pageResolution.cancel() }
        .task(id: model.navigationGeneration) {
          pageResolution.cancel()
          if let place = model.requestedReturn {
            await model.resolveReturnToPlace(place, viewport: viewport) { destination, complete in
              model.updatePresence(destination, settled: true); complete()
            }
            return
          }
          guard let reference = model.requestedReference else { return }
          await model.resolveReferenceLocation(reference) { location in
            model.macReveal(location, pageResolution: pageResolution)
          }
        }
      }
    }
  }

  private func pinned(_ presence: SessionPresence) -> Set<WorkspaceSpatialID> {
    var result = Set<WorkspaceSpatialID>()
    if let id = presence.focusedItemID { result.insert(.item(id)) }
    if let id = model.selectionSession.itemID(on: presence.boardID) { result.insert(.item(id)) }
    if case .spatial(_, let id) = model.selectionSession.element { result.insert(.element(id)) }
    return result
  }

  private struct ElementRevision: Equatable {
    let paint: UUID
    let content: UInt64
    let editing: InteractiveElementReference?
    let selection: NotebookSelectionSession.Target?
  }

  private func elements(_ values: [SpatialElement], presence: SessionPresence, cohort: SceneCompositionCohort) -> some View {
    let graph=model.presentedGraphicGraph(boardID:presence.boardID,cohort:cohort)
    return SceneCameraPlane(presence: presence, revision: ElementRevision(paint: cohort.paintID,
      content: model.collaborationReadEpoch, editing: model.interactiveElementFocus, selection: model.selectionSession.target),
      reanchorsOnRevision: false, isCameraActive: model.presencePhase == .active, installation: cohort.installation(for: .elements), hitRegions: { anchor in
        values.compactMap { element in
          let presentation=model.elementPresentation(.spatial(boardID:presence.boardID,elementID:element.id),graph:graph)
          guard let origin=presentation?.placement.origin ?? element.worldOrigin else { return nil }
          let point = anchor.camera.worldToScreen(origin, viewport: anchor.viewport)
          let f = presentation?.frame ?? model.elementPresentationFrame(.spatial(boardID: presence.boardID, elementID: element.id),
            fallback: .init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height))
          let scale = anchor.camera.scale
          return CGRect(x: point.x + f.x * scale, y: point.y + f.y * scale, width: f.width * scale, height: f.height * scale)
        }
      }) { anchor in
      ZStack {
        ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: .board(presence.boardID), layer: .elements, presence: anchor)) { band in
          band.zIndex(Double(band.rank))
        }
        ForEach(cohort.plan.vectorRuns.filter { $0.plane == .board(presence.boardID) }) { run in
          NotebookGraphicBatchView(run: run, elements: values,
            graph: model.presentedGraphicGraph(boardID: presence.boardID, cohort: cohort),
            scale: anchor.camera.scale, size: .init(width: anchor.viewport.x, height: anchor.viewport.y),
            projectOrigin: { anchor.camera.worldToScreen($0, viewport: anchor.viewport).cgPoint })
            .zIndex(cohort.plan.rank(id: run.id.id, in: run.plane) ?? 0)
        }
        ForEach(values) { element in
          let presentation=model.elementPresentation(.spatial(boardID:presence.boardID,elementID:element.id),graph:graph)
          if let origin=presentation?.placement.origin ?? element.worldOrigin {
            let reference = EditableElementReference.spatial(boardID: presence.boardID, elementID: element.id)
            let frame = presentation?.frame ?? model.elementPresentationFrame(reference, fallback: .init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height))
            let point = anchor.camera.worldToScreen(origin, viewport: anchor.viewport)
            EditableElementContainer(reference: reference) {
              if element.graphic != nil || !cohort.plan.allowsLive(.element(element.id), in: .board(presence.boardID)) { Color.clear }
              else if let presentation {
                NotebookPlacedElement(presentation:presentation) {
                  SpatialElementContent(element: element, boardID: presence.boardID,
                    isTextEditing: model.interactiveElementFocus == .board(boardID: presence.boardID, elementID: element.id),
                    onTextEditingEnded: { model.interactiveElementFocus = nil })
                }
              }
            }
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(anchor.camera.scale)
            .frame(width: frame.width * anchor.camera.scale, height: frame.height * anchor.camera.scale)
            .position(x: point.x + (frame.x + frame.width / 2) * anchor.camera.scale,
              y: point.y + (frame.y + frame.height / 2) * anchor.camera.scale)
            .zIndex(cohort.plan.rank(id: .element(element.id), in: .board(presence.boardID)) ?? 0)
          }
        }
      }.coordinateSpace(name: NotebookManipulationSpace.material)
        .environment(model).environment(\.sceneComposition, .init(cohort))
    }
  }

  private struct ItemRevision: Equatable {
    let paint: UUID
    let content: UInt64
    let focus: UUID?
    let mode: WorkspaceSemanticMode
    let page: UUID?
    let documentPage: Int
    let selection: NotebookSelectionSession.Target?
  }

  private func items(_ values: [RenderedWorkspaceItem], presence: SessionPresence, cohort: SceneCompositionCohort) -> some View {
    SceneCameraPlane(presence: presence,
      revision: ItemRevision(paint: cohort.paintID, content: model.collaborationReadEpoch, focus: presence.focusedItemID, mode: presence.mode, page: presence.notebookPageID, documentPage: presence.documentPageIndex, selection: model.selectionSession.target),
      reanchorsOnRevision: false, isCameraActive: model.presencePhase == .active, installation: cohort.installation(for: .covers), hitRegions: { anchor in
        values.map { item in
          let center = anchor.camera.worldToScreen(item.center, viewport: anchor.viewport)
          let width = item.geometry.width * anchor.camera.scale, height = item.geometry.height * anchor.camera.scale
          return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        }
      }) { anchor in
      ZStack {
        ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: .board(presence.boardID), layer: .covers, presence: anchor)) { band in
          band.zIndex(Double(band.rank))
        }
        ForEach(values) { item in
          let center = anchor.camera.worldToScreen(item.center, viewport: anchor.viewport)
          MacWorkspaceMaterial(item: item, presence: anchor, cohort: cohort)
            .frame(width: item.geometry.width, height: item.geometry.height)
            .scaleEffect(anchor.camera.scale)
            .frame(width: item.geometry.width * anchor.camera.scale, height: item.geometry.height * anchor.camera.scale)
            .position(x: center.x, y: center.y)
            .zIndex(WorkspaceSceneProjection.presentationRank(of: item, in: presence)
              ?? cohort.plan.rank(id: .item(item.id), in: .board(presence.boardID)) ?? 0)
        }
      }.coordinateSpace(name: NotebookManipulationSpace.material)
        .environment(model).environment(\.sceneComposition, .init(cohort))
    }
  }
}

private struct MacWorkspaceMaterial: View {
  @Environment(NotebookAppModel.self) private var model
  let item: RenderedWorkspaceItem
  let presence: SessionPresence
  let cohort: SceneCompositionCohort
  @State private var source = UUID()
  @State private var draggedFrom: WorldPoint?
  @State private var moveSource: NotebookItemMoveSource?
  @State private var translation = CGSize.zero
  private var isLive: Bool { cohort.plan.allowsLive(.item(item.id), in: .board(presence.boardID)) }
  private var title: String { item.item.title.isEmpty ? (item.item.kind == .notebook ? "Тетрадь" : item.item.kind == .document ? "Документ" : "Доска") : item.item.title }
  private var editingTextID: String? {
    if case .board(let board, let element) = model.interactiveElementFocus, board == presence.boardID { return element }
    return nil
  }
  private var isSelected: Bool { model.selectionSession.itemID(on: presence.boardID) == item.id }

  var body: some View {
    Group {
      if isLive {
        WorkspaceItemCoverView(item: item.item, boardID: presence.boardID, geometry: item.geometry,
          spatialInkSurfaces: model.compositionTiles.surfaceRegistry,
          elements: model.presentedCoverElements(cohort: cohort, boardID: presence.boardID, itemID: item.id),
          editingTextID: editingTextID, portalOpenProgress: 0, portalViewport: presence.viewport,
          onTap: { _, _ in }, onTextEditingEnded: { _ in model.interactiveElementFocus = nil },
          portalPixelScale: presence.camera.scale)
      } else { Color.clear }
    }
    .contentShape(RoundedRectangle(cornerRadius: item.geometry.cornerRadius))
    .overlay { if isSelected { RoundedRectangle(cornerRadius: item.geometry.cornerRadius).stroke(.tint, lineWidth: 2 / presence.camera.scale).allowsHitTesting(false) } }
    .onTapGesture(count: 2) { model.macOpenItem(item.id) }
    .onTapGesture { model.selectWorkspaceItem(item.id, boardID: presence.boardID) }
    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(NotebookManipulationSpace.material)).onChanged { value in
      if draggedFrom == nil {
        guard model.inputGate.beginFingerSequence() != nil,
          let captured = model.itemMoveSource(item.id, boardID: presence.boardID,
            shown: model.presentedHierarchy(cohort: cohort).board(presence.boardID)) else { return }
        if isLive { model.inputGate.beginContact(source: source) }
        model.inputGate.registerFingerCancellation(source: source) {
          draggedFrom = nil; moveSource = nil; translation = .zero
          model.inputGate.endContact(source: source)
        }
        draggedFrom = item.center
        moveSource = captured
        model.selectWorkspaceItem(item.id, boardID: presence.boardID)
      }
      translation = CGSize(width: value.translation.width / presence.camera.scale,
        height: value.translation.height / presence.camera.scale)
    }.onEnded { value in
      if let origin = draggedFrom, let destination = origin.addressOffset(x: value.translation.width / presence.camera.scale, y: value.translation.height / presence.camera.scale) {
        model.moveItem(item.id, to: destination, source: moveSource)
      }
      draggedFrom = nil; moveSource = nil; translation = .zero
      model.inputGate.unregisterFingerCancellation(source: source)
      model.inputGate.endContact(source: source)
    }, including: editingTextID == nil ? .all : .subviews)
    .contextMenu {
      Button("Открыть") { model.macOpenItem(item.id) }
      Button("Удалить", role: .destructive) { Task { await model.deleteItem(item.id) } }
    }
    .onChange(of: isLive) { _, live in
      if live, draggedFrom != nil { model.inputGate.beginContact(source: source) }
    }
    .onDisappear {
      model.inputGate.unregisterFingerCancellation(source: source)
      model.inputGate.endContact(source: source)
    }
    .clipShape(RoundedRectangle(cornerRadius: item.geometry.cornerRadius))
    .background { if isLive { WorkspaceItemShadow(geometry: item.geometry, kind: item.item.kind,
      hasContents: cohort.liveData.nonemptyBoardIDs.contains(item.id)) } }
    .offset(translation)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("workspace-item-\(item.id.uuidString.lowercased())")
  }
}
