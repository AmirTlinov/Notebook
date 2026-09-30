import NotebookCore
import SwiftUI

/// A contiguous native run in the existing camera plane. One Canvas paints
/// every path in source order; only the active label has an input view. The
/// parent supplies its installed projection, never a second graphics camera.
struct NotebookGraphicBatchView: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.sceneComposition) private var composition
  let run: SceneCompositionVectorRun
  let elements: [SpatialElement]
  let graph: NotebookGraphicGraph
  let scale: Double
  let size: CGSize
  let projectOrigin: (WorldPoint) -> CGPoint
  var commitsState = true

  private struct Object: Identifiable {
    let element: SpatialElement
    let graphic: NotebookGraphic
    let layout: NotebookGraphicLayout
    let frame: CGRect
    let targetGraphic:NotebookGraphic
    let targetLayout:NotebookGraphicLayout
    let targetFrame:CGRect
    var id: String { element.id }
  }

  private var objects: [Object] {
    let sources = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
    return run.owners.compactMap { owner in
      guard case .element(let id) = owner.id, let element = sources[id],let graphic=graph.nodes[id]?.graphic else {return nil}
      let reference=EditableElementReference.spatial(boardID:run.plane.boardID,elementID:id)
      #if os(iOS)
      let held=commitsState ? model.selectedGraphicHosts.heldMember(reference) : nil
      #else
      let held:NotebookGraphicSelection.Member?=nil
      #endif
      guard let targetLayout=graph.resolve(id).layout else {return nil}
      func screen(_ layout:NotebookGraphicLayout)->CGRect {
        let origin=projectOrigin(layout.origin),local=layout.frame
        return .init(x:origin.x+local.x*scale,y:origin.y+local.y*scale,
          width:local.width*scale,height:local.height*scale)
      }
      let layout=held?.layout ?? targetLayout
      return .init(element:element,graphic:held?.graphic ?? graphic,layout:layout,frame:screen(layout),
        targetGraphic:graphic,targetLayout:targetLayout,targetFrame:screen(targetLayout))
    }
  }
  private func ordered(_ id:String)->Bool {
    guard let node=graph.node(id),node.placement.parentID == nil else {return false}
    return node.graphic.sourceInkContactID != nil
  }
  private var editingID: String? {
    guard commitsState, case .board(let boardID, let id) = model.interactiveElementFocus,
      boardID == run.plane.boardID else { return nil }
    return id
  }

  var body: some View {
    let objects = objects
    #if os(iOS)
    let selectedIDs=commitsState ? model.selectedGraphicHosts.selectedIDs(boardID:run.plane.boardID) : [:]
    #else
    let selectedIDs:[String:UUID]=[:]
    #endif
    let editingID=editingID.flatMap { model.selectionSession.isInteractive || selectedIDs[$0] == nil ? $0 : nil }
    let surface: SurfaceID = run.plane.coverID.map(SurfaceID.cover) ?? .board(run.plane.boardID)
    let erasures = model.elementErasures(on: surface, fallback: composition.cohort?.liveData.ink)
    let appearances = Dictionary(uniqueKeysWithValues: objects.compactMap { object -> (String, NotebookElementAppearance)? in
      guard let value = model.elementErasureCache.appearance(surface:surface,id:object.id,
        graphic:object.graphic,layout:object.layout,
        size:.init(width:object.layout.frame.width,height:object.layout.frame.height),erasures:erasures[object.id] ?? [],prepares:!model.isElementErasing(object.id,on:surface)) else { return nil }
      return (object.id,value)
    })
    ZStack(alignment: .topLeading) {
      ForEach(paintRuns(objects.filter { $0.id != editingID },erasures:erasures,selected:selectedIDs)) { part in
        if case .selected(let selectionID)=part.kind,let object=part.objects.first {
          #if os(iOS)
          // The accessibility representation lives inside the moving native
          // body, not on the stationary Canvas wrapper. Its existing element
          // actions and focus frame then travel with the installed pose.
          NotebookSelectedGraphicHost(reference:reference(object.id),selectionID:selectionID,size:object.frame.size,
            graphic:object.graphic,layout:object.layout,targetGraphic:object.targetGraphic,
            targetLayout:object.targetLayout,targetSize:object.targetFrame.size,
            targetOffset:CGPoint(x:object.targetFrame.midX-object.frame.midX,
              y:object.targetFrame.midY-object.frame.midY),
            targetContent:AnyView(selectedBody(object,graphic:object.targetGraphic,layout:object.targetLayout,
              frame:object.targetFrame,erasures:erasures[object.id] ?? [],appearance:appearances[object.id])
              .accessibilityRepresentation {
                accessibleObject(object).accessibilityHidden(appearances[object.id]?.state == .erased)
              })) {
            selectedBody(object,graphic:object.graphic,layout:object.layout,
              frame:object.frame,erasures:erasures[object.id] ?? [],appearance:appearances[object.id])
              .accessibilityRepresentation {
                accessibleObject(object).accessibilityHidden(appearances[object.id]?.state == .erased)
              }
          }
          .frame(width:object.frame.width,height:object.frame.height)
          .position(x:object.frame.midX,y:object.frame.midY)
          .allowsHitTesting(false)
          #else
          NotebookGraphicView(graphic:object.graphic,layout:object.layout)
            .frame(width:object.frame.width,height:object.frame.height)
            .position(x:object.frame.midX,y:object.frame.midY)
            .accessibilityRepresentation {
              accessibleObject(object)
                .accessibilityHidden(appearances[object.id]?.state == .erased
                  || (!(erasures[object.id] ?? []).isEmpty && appearances[object.id] == nil))
            }
          #endif
        } else if case .material=part.kind,let object=part.objects.first {
          NotebookGraphicView(graphic:object.graphic,layout:object.layout,
            erasures:erasures[object.id] ?? [],appearance:appearances[object.id],paintsMeasuredBody:!ordered(object.id))
            .environment(\.inkMaterialReadiness,materialReadiness(object.id))
            .frame(width:object.layout.frame.width,height:object.layout.frame.height)
            .scaleEffect(scale)
            .frame(width:object.frame.width,height:object.frame.height)
            .position(x:object.frame.midX,y:object.frame.midY)
            .accessibilityRepresentation {
              accessibleObject(object)
                .accessibilityHidden(appearances[object.id]?.state == .erased
                  || (!(erasures[object.id] ?? []).isEmpty && appearances[object.id] == nil))
            }
        } else {
          Canvas { context, _ in
            for object in part.objects {
              var local=context
              local.translateBy(x:object.frame.minX,y:object.frame.minY)
              local.scaleBy(x:scale,y:scale)
              NotebookGraphicView.paint(object.graphic,layout:object.layout,in:local,
                size:.init(width:object.layout.frame.width,height:object.layout.frame.height))
            }
          }
          .accessibilityRepresentation {
            ZStack(alignment:.topLeading) {
              ForEach(part.objects) { object in
                let erased=appearances[object.id]?.state == .erased
                accessibleObject(object)
                  .accessibilityHidden(erased || (!(erasures[object.id] ?? []).isEmpty && appearances[object.id] == nil))
                  .frame(width:object.frame.width,height:object.frame.height)
                  .position(x:object.frame.midX,y:object.frame.midY)
              }
            }.frame(width:size.width,height:size.height)
          }
        }
      }
      .allowsHitTesting(false)
      if let object = objects.first(where: { $0.id == editingID }) {
        NotebookGraphicElementView(graphic: object.graphic, reference: reference(object.id), layout: object.layout,
          erasures:erasures[object.id] ?? [],appearance:appearances[object.id],paintsMeasuredBody:!ordered(object.id))
          .frame(width: object.layout.frame.width, height: object.layout.frame.height)
          .environment(\.inkMaterialReadiness,materialReadiness(object.id))
          .scaleEffect(scale)
          .frame(width: object.frame.width, height: object.frame.height)
          .position(x: object.frame.midX, y: object.frame.midY)
      }
    }.frame(width: size.width, height: size.height)
  }

  private func materialReadiness(_ element:String) -> NotebookInkMaterialReceiver? {
    guard let cohort=composition.cohort else { return nil }
    let address=SceneSourceAddress(plane:run.plane,elementID:element)
    return .init(id:cohort.paintID,report:{ id,content,ready in cohort.recordMaterial(address,id:id,content:content,ready:ready) })
  }
  private func selectedBody(_ object:Object,graphic:NotebookGraphic,layout:NotebookGraphicLayout,
    frame:CGRect,erasures:[InkElementErasure],appearance:NotebookElementAppearance?) -> some View {
    NotebookGraphicElementView(graphic:graphic,reference:reference(object.id),layout:layout,
      erasures:erasures,appearance:appearance,paintsMeasuredBody:!ordered(object.id))
      .frame(width:layout.frame.width,height:layout.frame.height)
      .environment(\.inkMaterialReadiness,materialReadiness(object.id))
      .scaleEffect(scale)
      .frame(width:frame.width,height:frame.height)
  }

  private struct PaintRun: Identifiable {
    enum Kind {case vector,material,selected(UUID)}
    let id:String
    let kind:Kind
    var objects:[Object]
  }
  private func paintRuns(_ objects:[Object],erasures:InkElementErasureMap,selected:[String:UUID]) -> [PaintRun] {
    var runs:[PaintRun]=[]
    for object in objects {
      let graphic=object.graphic
      if graphic.sourceInkContactID == nil,let selectionID=selected[object.id] {
        runs.append(.init(id:object.id,kind:.selected(selectionID),objects:[object]));continue
      }
      let material=graphic.freehand != nil || graphic.mask?.operations.contains(where:{ $0.erasures != nil }) == true || !(erasures[object.id] ?? []).isEmpty
      if !material,let last=runs.last,case .vector=last.kind {runs[runs.count-1].objects.append(object)}
      else {runs.append(.init(id:object.id,kind:material ? .material:.vector,objects:[object]))}
    }
    return runs
  }

  private func reference(_ id: String) -> EditableElementReference {
    .spatial(boardID: run.plane.boardID, elementID: id)
  }

  @ViewBuilder private func accessibleObject(_ object: Object) -> some View {
    let graphic = graph.nodes[object.id]!.graphic
    let content = Color.clear.accessibilityElement(children: .ignore)
      .accessibilityLabel(graphic.label.isEmpty ? graphic.shape.displayName : graphic.label)
      .accessibilityAddTraits(.isImage)
    if commitsState {
      EditableElementContainer(reference: reference(object.id)) { content }
    } else { content }
  }
}
