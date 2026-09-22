import Foundation
import NotebookCore

/// Exact persisted source of the preceding command on this physical element.
/// The serial writer may advance our own source, never silently rebase onto a
/// peer's edit. A failed predecessor cancels its dependent commands.
struct NotebookElementCommandResult: Sendable {
  let page: AgentElement?
  let spatial: SpatialElement?
  var boardHeader: BoardDocument? = nil
}

struct NotebookElementCommand {
  let id: UUID
  let task: Task<NotebookElementCommandResult?, Never>
  var cursor: UInt64?
}

struct NotebookElementCommandDraft: Equatable {
  let source: NotebookElementPlacement.Source
  let graphic: NotebookGraphic?
  var capture: NotebookGraphicContactSource? = nil
  var removed = false
  var textSource: String? = nil
  var textHTML: String? = nil
  var textStyle: NativeTextStyle? = nil
  var frame: PageRect { source.frame }
  var basis: NotebookElementBasis? { source.basis }
  var rect: CGRect { .init(x: frame.x, y: frame.y, width: frame.width, height: frame.height) }

  /// Same accepted draft as the native body and controls; its causal stamp
  /// remains unresolved until this command's own writer result is available.
  func projecting(_ element:SpatialElement) -> SpatialElement? {
    guard !removed else { return nil }
    return .init(id:element.id,surface:element.surface,kind:element.kind,
      frame:.init(x:frame.x,y:frame.y,width:frame.width,height:frame.height),worldOrigin:element.worldOrigin,
      source:textSource ?? element.source,html:textHTML ?? element.html,css:element.css,javaScript:element.javaScript,
      programPackage:element.programPackage,state:element.state,textStyle:textStyle ?? element.textStyle,
      graphic:graphic,parentID:source.parentID,basis:basis,stamp:element.stamp)
  }

}

extension NotebookAppModel {
  func retireGraphicCommands(through cursor: UInt64) {
    for (reference, command) in elementCommandSources {
      guard !editingNativeTextReferences.contains(reference), let accepted = command.cursor, cursor >= accepted else { continue }
      elementCommandSources[reference] = nil
      elementCommandDrafts[reference] = nil
    }
  }

  func retainedGraphicGraph(includingGroups:Bool = true,reference:(String) -> EditableElementReference) -> NotebookGraphicGraph? {
    if let contact=selectionSession.manipulation,reference(contact.reference.elementID) == contact.reference,
      let captured=contact.graphicCapture,includingGroups || !captured.source.isGroup { return captured.graph }
    return elementCommandDrafts.first { ref,draft in
      reference(ref.elementID) == ref && draft.capture != nil && (includingGroups || !draft.source.isGroup)
    }?.value.capture?.graph
  }

  /// Whole and leaf drafts enter the one placement resolver before children
  /// are resolved. Never rewrite each child's local frame to preview its parent.
  func elementPlacementDrafts(reference: (String) -> EditableElementReference) -> [String:NotebookElementPlacement.Source] {
    var result:[String:NotebookElementPlacement.Source]=[:]
    for (ref,draft) in elementCommandDrafts {
      let id:String
      switch ref { case .page(_,let value),.spatial(_,let value): id=value }
      if reference(id) == ref { result[id]=draft.source }
    }
    if let contact=selectionSession.manipulation {
      let ref=contact.reference,id:String
      switch ref { case .page(_,let value),.spatial(_,let value): id=value }
      if reference(id) == ref,var source=result[id] ?? contact.graphicCapture?.source ?? nativeElementSource(ref)?.placementSource {
        source.frame = .init(x:contact.frame.minX,y:contact.frame.minY,width:contact.frame.width,height:contact.frame.height)
        source.basis=contact.basis;result[id]=source
      }
    }
    return result
  }

  /// Contact and accepted edits share the existing graph, renderer and camera.
  /// Only nodes already admitted by that graph can change here.
  func projectingGraphicCommands(_ graph: NotebookGraphicGraph,
    publishedGroups: [String:NotebookElementPlacement.Source]? = nil,
    reference: (String) -> EditableElementReference) -> NotebookGraphicGraph {
    let selectedEdits=selectionSession.manipulation?.selectedEdits ?? []
    let placements=elementPlacementDrafts(reference:reference)
    var graphics:[String:NotebookGraphic]=[:]
    for (ref,draft) in elementCommandDrafts {
      let id=ref.elementID
      if reference(id) == ref,let graphic=draft.graphic { graphics[id]=graphic }
    }
    if let contact=selectionSession.manipulation,reference(contact.reference.elementID) == contact.reference,
      var graphic=graphics[contact.reference.elementID] ?? graph.node(contact.reference.elementID)?.graphic {
      if let connection=contact.connection { graphic.connection=connection }
      if contact.vertices != contact.originalVertices { graphic.vertices=contact.vertices }
      if contact.cornerRadius != contact.originalCornerRadius { graphic.cornerRadius=contact.cornerRadius }
      graphics[contact.reference.elementID]=graphic
    }
    var sources=placements
    if let publishedGroups {
      sources=sources.filter { !$0.value.isGroup }
      sources.merge(publishedGroups) { _,published in published }
    }
    for selected in selectedEdits where graph.node(selected.id) != nil {
      graphics[selected.id]=selected.graphic
      if var source=graph.source(selected.id) { source.frame=selected.frame;sources[selected.id]=source }
    }
    return graph.projecting(placements:sources,graphics:graphics)
  }
}

struct NotebookElementEdit: Equatable, Sendable {
  let reference: EditableElementReference
  let kind: CollaborationOperation.Kind
  let values: [String: JSONValue]
}

/// A contact retains the exact admitted graph, just as it retains its input
/// settings. Lift transfers this source to the existing command draft; disposal
/// of that draft also disposes of the captured graph, without a global cache.
final class NotebookGraphicContactSource: Equatable, Sendable {
  let graph:NotebookGraphicGraph
  let source:NotebookElementPlacement.Source
  let closedGroup:Bool
  let bounds:CGRect?
  init(graph:NotebookGraphicGraph,source:NotebookElementPlacement.Source,id:String,closedGroup:Bool? = nil) {
    self.graph=graph;self.source=source;self.closedGroup=closedGroup ?? (source.isGroup && graph.groupIsSelfContained(id));bounds=nil
  }
  private init(_ original:NotebookGraphicContactSource,bounds:CGRect) {
    graph=original.graph;source=original.source;closedGroup=original.closedGroup;self.bounds=bounds
  }
  func retaining(bounds:CGRect) -> NotebookGraphicContactSource { .init(self,bounds:bounds) }
  static func == (a:NotebookGraphicContactSource,b:NotebookGraphicContactSource) -> Bool { a === b }
}
