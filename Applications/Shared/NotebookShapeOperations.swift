import CoreGraphics
import NotebookCore

extension NotebookAppModel {
  /// A single causal action replaces the first operand and hides the rest.
  /// Their immutable source-ink claims remain intact; ordinary undo restores all.
  func combineAuthoredShape(_ object: NotebookWorkingGraphic, at address: NotebookToolAddress,
    graph: NotebookGraphicGraph, operation: NotebookShapeOperation) {
    updateWorkingGraphic(nil,strokeID:object.strokeID)
    let origin = address.worldOrigin ?? .zero
    func outline(_ graphic: NotebookGraphic, _ frame: PageRect, _ delta: SpatialPoint = .zero) -> CGPath {
      let inset = min(graphic.style.strokeWidth/2,min(frame.width,frame.height)/2-0.01)
      return NotebookGraphicGeometry.outlinePath(graphic,in:CGRect(x:frame.x+delta.x,y:frame.y+delta.y,
        width:frame.width,height:frame.height).insetBy(dx:max(0,inset),dy:max(0,inset)))
    }
    let cutter = outline(object.graphic,object.frame)
    let operands = graph.nodes.values.filter { node in
      guard node.surface == address.surface, node.shown,
        ![NotebookGraphic.Shape.connector,.freehand,.plus].contains(node.graphic.shape) else { return false }
      return outline(node.graphic,node.frame,origin.delta(to:node.origin)).intersects(cutter)
    }.sorted { $0.id < $1.id }
    guard let first = operands.first else {
      if operation == .union || operation == .exclude { acceptAuthoredGraphic(object,at:address) }
      else { showCue("Нарисуйте фигуру поверх другой фигуры.") }
      return
    }
    guard operands.count <= 32 else { showCue("Выберите не более 32 фигур."); return }
    var base: CGPath = CGMutablePath()
    for node in operands { base = base.union(outline(node.graphic,node.frame,origin.delta(to:node.origin))) }
    let result: CGPath
    switch operation {
    case .normal: return
    case .union: result = base.union(cutter)
    case .subtract: result = base.subtracting(cutter)
    case .intersect: result = base.intersection(cutter)
    case .exclude: result = base.symmetricDifference(cutter)
    }
    do {
      var edits = operands.dropFirst().map { NotebookElementEdit(reference:address.reference($0.id),kind:.removeElement,values:[:]) }
      if result.isEmpty {
        edits.append(.init(reference:address.reference(first.id),kind:.removeElement,values:[:]))
      } else {
        let box = result.boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return }
        let vector = NotebookVectorPath(path:result,frame:box)
        guard vector.isValid else { showCue("Слишком сложный контур: объедините меньше фигур."); return }
        let frame = box.insetBy(dx:-object.graphic.style.strokeWidth/2,dy:-object.graphic.style.strokeWidth/2)
        let delta = origin.delta(to:first.origin)
        let patch: [String:JSONValue] = ["shape":.string("path"),"path":try .encode(vector),
          "vertices":.null,"cornerRadius":.null,"transform":.null,"style":try .encode(object.graphic.style)]
        edits.insert(.init(reference:address.reference(first.id),kind:.updateElement,values:[
          "frame":try .encode(PageRect(x:frame.minX-delta.x,y:frame.minY-delta.y,width:frame.width,height:frame.height)),
          "graphic":.object(patch)]),at:0)
      }
      if performElementOperations(edits,summary:operation.title + " фигур") {
        if result.isEmpty { clearSelection() } else { selectElement(address.reference(first.id)) }
      }
    } catch { showCue(error.localizedDescription) }
  }
}
