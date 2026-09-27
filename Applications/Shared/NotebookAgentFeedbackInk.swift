import NotebookCore
import CoreGraphics
import Foundation

/// Feedback borrows immutable contacts and the canonical freehand geometry.
/// It prepares one episode mask off-main; camera movement only projects it.
enum NotebookAgentFeedbackInk {
  enum Source:Sendable {case page(PageInkSource),spatial(SpatialInkJournal)}
  struct Input:Sendable {
    let source:Source
    let strokeID:UUID
    let surface:SurfaceID
    let region:PageRect
    let origin:WorldPoint?
  }
  struct Material:@unchecked Sendable {
    let path:CGPath
    let readSet:NotebookInkReadSet
    let region:PageRect
    let origin:WorldPoint?
  }
  static func prepare(_ input:Input) throws -> Material? {
    try Task.checkCancellation()
    let region=input.region
    let readSet:NotebookInkReadSet
    var layers:[NotebookFreehand.Layer]=[]
    func append(id:UUID,span:Int,tool:SpatialInkTool,color:SpatialInkColor,samples:InkMeasurements) {
      layers.append(.init(tool:tool,color:color,measured:.init(sourceID:id,span:span,measurements:samples,frame:region,origin:input.origin)))
    }
    switch input.source {
    case .page(let source):
      guard let set=source.readSet(for:input.strokeID,on:input.surface),let drawing=source.preparedDrawing,
        set.contact.tool == .pen else {return nil}
      readSet=set
      for witness in [set.contact]+set.erasers.sorted(by:{$0.precedes($1)}) {
        try Task.checkCancellation()
        guard let action=drawing.action(id:witness.id) else {return nil}
        append(id:action.id,span:0,tool:action.tool,color:action.color,samples:action.samples)
      }
    case .spatial(let journal):
      guard let set=journal.readSet(for:input.strokeID,on:input.surface),set.contact.tool == .pen else {return nil}
      readSet=set
      for witness in [set.contact]+set.erasers.sorted(by:{$0.precedes($1)}) {
        try Task.checkCancellation()
        guard let action=journal.action(id:witness.id) else {return nil}
        for (index,span) in action.spans.enumerated() where span.surface == input.surface {
          append(id:action.id,span:index,tool:action.tool,color:action.color,samples:span.samples)
        }
      }
    }
    let geometry=NotebookFreehand(layers:layers).geometry
    let path=geometry.paintPath(size:.init(width:region.width,height:region.height),transform:nil)
    try Task.checkCancellation()
    return .init(path:path,readSet:readSet,region:region,origin:input.origin)
  }
}
