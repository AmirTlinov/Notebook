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
    let layout: NotebookGraphicLayout
    let frame: CGRect
    var id: String { element.id }
  }

  private var objects: [Object] {
    let sources = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
    return run.owners.compactMap { owner in
      guard case .element(let id) = owner.id, let element = sources[id], element.graphic != nil,
        let layout = graph.resolve(id).layout else { return nil }
      let origin = projectOrigin(layout.origin), local = layout.frame
      return .init(element: element, layout: layout, frame: .init(
        x: origin.x + local.x * scale, y: origin.y + local.y * scale,
        width: local.width * scale, height: local.height * scale))
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
    let objects = objects, editingID = editingID
    let surface: SurfaceID = run.plane.coverID.map(SurfaceID.cover) ?? .board(run.plane.boardID)
    let erasures = model.elementErasures(on: surface, fallback: composition.cohort?.liveData.ink)
    let appearances = Dictionary(uniqueKeysWithValues: objects.compactMap { object -> (String, NotebookElementAppearance)? in
      guard let value = model.elementErasureCache.appearance(surface:surface,id:object.id,
        graphic:graph.nodes[object.id]?.graphic,layout:object.layout,
        size:.init(width:object.layout.frame.width,height:object.layout.frame.height),erasures:erasures[object.id] ?? [],prepares:!model.isElementErasing(object.id,on:surface)) else { return nil }
      return (object.id,value)
    })
    ZStack(alignment: .topLeading) {
      ForEach(paintRuns(objects.filter { $0.id != editingID }, erasures:erasures)) { part in
        if part.isMaterial,let object=part.objects.first {
          NotebookGraphicView(graphic:graph.nodes[object.id]!.graphic,layout:object.layout,
            erasures:erasures[object.id] ?? [],appearance:appearances[object.id],paintsMeasuredBody:!ordered(object.id))
            .environment(\.inkMaterialReadiness,materialReadiness(object.id))
            .frame(width:object.layout.frame.width,height:object.layout.frame.height)
            .scaleEffect(scale)
            .frame(width:object.frame.width,height:object.frame.height)
            .position(x:object.frame.midX,y:object.frame.midY)
        } else {
          Canvas { context, _ in
            for object in part.objects {
              var local=context
              local.translateBy(x:object.frame.minX,y:object.frame.minY)
              local.scaleBy(x:scale,y:scale)
              NotebookGraphicView.paint(graph.nodes[object.id]!.graphic,layout:object.layout,in:local,
                size:.init(width:object.layout.frame.width,height:object.layout.frame.height))
            }
          }
        }
      }
      .accessibilityRepresentation {
        ZStack(alignment: .topLeading) {
          ForEach(objects.filter { $0.id != editingID }) { object in
            let erased = appearances[object.id]?.state == .erased
            accessibleObject(object)
              .accessibilityHidden(erased || (!(erasures[object.id] ?? []).isEmpty && appearances[object.id] == nil))
              .frame(width: object.frame.width, height: object.frame.height)
              .position(x: object.frame.midX, y: object.frame.midY)
          }
        }.frame(width: size.width, height: size.height)
      }
      .allowsHitTesting(false)
      if let object = objects.first(where: { $0.id == editingID }) {
        NotebookGraphicElementView(graphic: graph.nodes[object.id]!.graphic, reference: reference(object.id), layout: object.layout,
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

  private struct PaintRun: Identifiable {
    let id:String
    let isMaterial:Bool
    var objects:[Object]
  }
  private func paintRuns(_ objects:[Object],erasures:[String:[InkElementErasure]]) -> [PaintRun] {
    var runs:[PaintRun]=[]
    for object in objects {
      let graphic=graph.nodes[object.id]?.graphic
      let material=graphic?.freehand != nil || graphic?.mask?.operations.contains(where:{ $0.erasures != nil }) == true || !(erasures[object.id] ?? []).isEmpty
      if !material,runs.last?.isMaterial == false { runs[runs.count-1].objects.append(object) }
      else { runs.append(.init(id:object.id,isMaterial:material,objects:[object])) }
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
