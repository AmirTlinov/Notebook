import CoreGraphics
import Foundation
import NotebookCore

/// Page graphics and raw identity are resolved from the same accepted page.
/// Decoding remains on the existing page worker; a same-stamp pose/cut change
/// still changes this immutable input and cannot disappear behind raw equality.
struct NotebookPageOrderedInkInput:Equatable,Sendable {
  struct Candidate:Equatable,Sendable {
    let id:String
    let graphic:NotebookGraphic
    let layout:NotebookGraphicLayout
    let erasures:[InkElementErasure]
  }
  let candidates:[Candidate]
  let suppressedInkIDs:Set<UUID>
  static let empty=Self(candidates:[],suppressedInkIDs:[])
  /// Candidates are the caller's already admitted graphic window. Both live
  /// paper and exact export use this same winner/cut test before reading ranks.
  init(elements:[AgentElement],graph:NotebookGraphicGraph,layouts:[String:NotebookGraphicLayout],
    erasures:[String:[InkElementErasure]],suppressedInkIDs:Set<UUID>) {
    candidates=elements.compactMap { element in
      guard let node=graph.node(element.id),node.shown,node.placement.parentID == nil,
        node.graphic.showsGeometry,node.graphic.sourceInkContactID != nil,
        node.graphic.mask?.erasesWholeRegion != true,
        !(erasures[element.id] ?? []).contains(where:{$0.target.wholeElement}),
        let layout=layouts[element.id] else {return nil}
      return .init(id:element.id,graphic:node.graphic,layout:layout,erasures:erasures[element.id] ?? [])
    }
    self.suppressedInkIDs=suppressedInkIDs
  }
  init(candidates:[Candidate],suppressedInkIDs:Set<UUID>) {
    self.candidates=candidates;self.suppressedInkIDs=suppressedInkIDs
  }
  func matches(_ plan:NotebookOrderedInkPlan)->Bool {
    guard suppressedInkIDs == plan.suppressedInkIDs,candidates.count == plan.bodies.count else {return false}
    let byID=Dictionary(uniqueKeysWithValues:plan.bodies.map {($0.elementID,$0)})
    return candidates.allSatisfy { candidate in
      guard let body=byID[candidate.id] else {return false}
      return body.sourceID == candidate.graphic.sourceInkContactID
        && body.graphic == candidate.graphic && body.layout == candidate.layout && body.erasures == candidate.erasures
    }
  }
  func plan(drawing:PageInkDrawing) throws -> NotebookOrderedInkPlan {
    let bodies=try candidates.map { value -> NotebookOrderedInkPlan.Body in
      guard let id=value.graphic.sourceInkContactID,let action=drawing.action(id:id),action.tool == .pen else {
        throw SceneRenderError.snapshotPending("ordered_page_contact")
      }
      return .init(elementID:value.id,key:.page(sequence:action.sequence,id:id),graphic:value.graphic,layout:value.layout,erasures:value.erasures)
    }
    return .init(bodies:bodies,suppressedInkIDs:suppressedInkIDs)
  }
}

extension NotebookAppModel {
  func pageOrderedInk(_ page:PageDocument,display:NotebookPageGraphicDisplay)->NotebookPageOrderedInkInput {
    let working=workingGraphics.filter{$0.surface == .page(page.id)}
    var owners=Set<UUID>()
    let restoring=working.compactMap(\.inkPresentation).filter{owners.insert($0.id).inserted}
      .flatMap(\.retiringBodies)
    let restoringIDs=Set(restoring.map(\.elementID))
    let canonical=Set(working.filter {
      $0.inkPresentation?.needsCanonicalSource == true && ($0.publicationCursor.map {sceneContentCursor >= $0} ?? false)
    }.map(\.id))
    let held=Set(working.filter {
      $0.inkPresentation?.retainsRawSource($0.id) == true && !canonical.contains($0.id)
    }.map(\.id))
    let erasures=elementErasures(on:.page(page.id)),suppressed=pageSuppressedInkIDs(page)
    let ordinary=NotebookPageOrderedInkInput(elements:display.elements.filter{!held.contains($0.id) && !canonical.contains($0.id) && !restoringIDs.contains($0.id)},
      graph:display.graph,layouts:display.layouts,erasures:erasures,suppressedInkIDs:suppressed)
    let returned=restoring.map { NotebookPageOrderedInkInput.Candidate(id:$0.elementID,
      graphic:$0.graphic,layout:$0.layout,erasures:$0.erasures) }
    guard !canonical.isEmpty else {
      return .init(candidates:ordinary.candidates+returned,suppressedInkIDs:suppressed)
    }
    // Only the failed accepted members use the canonical source. The display
    // graph/controls keep their last pose until this plan is actually installed.
    let graph=page.graphicGraph(),elements=canonical.compactMap{page.element(id:$0)}
    let layouts=Dictionary(uniqueKeysWithValues:elements.compactMap {element in
      graph.resolve(element.id).layout.map{(element.id,$0)}
    })
    let accepted=NotebookPageOrderedInkInput(elements:elements,graph:graph,layouts:layouts,
      erasures:erasures,suppressedInkIDs:suppressed)
    return .init(candidates:ordinary.candidates+accepted.candidates+returned,suppressedInkIDs:suppressed)
  }
}
