import CoreGraphics
import Foundation
import NotebookCore

/// Admitted immutable inputs for one physical ink plane. Raw measurements stay
/// with its existing page/journal owner. Only source-anchored measured contacts
/// join this plan: arbitrary authored shapes and multi-contact region aggregates
/// have no single raw painter address and stay in the authored plane.
struct NotebookOrderedInkPlan: Equatable, Sendable {
  struct Body: Equatable, Sendable {
    let elementID:String
    let key:NotebookInkPaintKey
    let graphic:NotebookGraphic
    let layout:NotebookGraphicLayout
    let erasures:[InkElementErasure]
    var sourceID:UUID { key.actionID }
    init(elementID:String,key:NotebookInkPaintKey,graphic:NotebookGraphic,
      layout:NotebookGraphicLayout,erasures:[InkElementErasure]) {
      precondition(graphic.sourceInkContactID == key.actionID)
      self.elementID=elementID;self.key=key;self.graphic=graphic
      self.layout=layout;self.erasures=erasures
    }

  }
  private var paint:InkActionMap<NotebookInkPaintKey,Body>
  private var sourceKeys:InkActionMap<UUID,NotebookInkPaintKey>
  private var elementSources:InkActionMap<String,UUID>
  private(set) var suppressedInkIDs:Set<UUID>
  var bodies:InkActionMap<NotebookInkPaintKey,Body>.Values {paint.values}
  init(bodies:[Body] = [],suppressedInkIDs:Set<UUID> = []) {
    precondition(Set(bodies.map(\.sourceID)).count == bodies.count)
    precondition(Set(bodies.map(\.elementID)).count == bodies.count)
    paint = .init(entries:bodies.map{($0.key,$0)})
    sourceKeys = .init(entries:bodies.map{($0.sourceID,$0.key)})
    elementSources = .init(entries:bodies.map{($0.elementID,$0.sourceID)})
    self.suppressedInkIDs=suppressedInkIDs
  }
  init<S:Sequence>(bodies:S,suppressedInkIDs:Set<UUID> = []) where S.Element == Body {
    self.init(bodies:Array(bodies),suppressedInkIDs:suppressedInkIDs)
  }
  func body(sourceID:UUID)->Body? {sourceKeys[sourceID].flatMap{paint[$0]}}
  func body(elementID:String)->Body? {elementSources[elementID].flatMap{body(sourceID:$0)}}
  func matches(_ other:Self,ids:Set<UUID>)->Bool {
    ids.allSatisfy {body(sourceID:$0) == other.body(sourceID:$0)
      && suppressedInkIDs.contains($0) == other.suppressedInkIDs.contains($0)}
  }
  /// Only these addresses change. Unrelated bodies and painter ranks retain
  /// their captured roots, including through a rejected frame or restoration.
  func replacing(_ ids:Set<UUID>,from other:Self)->Self {
    var result=self
    let changed=ids.filter{body(sourceID:$0) != other.body(sourceID:$0)}
    for id in changed {
      guard let old=result.body(sourceID:id) else {continue}
      let next=other.body(sourceID:id)
      if next?.key != old.key {result.paint[old.key]=nil}
      if next == nil {result.sourceKeys[id]=nil}
      if next?.elementID != old.elementID {result.elementSources[old.elementID]=nil}
    }
    for id in changed {
      guard let next=other.body(sourceID:id) else {continue}
      precondition(result.elementSources[next.elementID].map{$0 == id} ?? true)
      result.paint[next.key]=next
      if result.sourceKeys[id] != next.key {result.sourceKeys[id]=next.key}
      if result.elementSources[next.elementID] != id {result.elementSources[next.elementID]=id}
    }
    for id in ids {
      let suppressed=other.suppressedInkIDs.contains(id)
      guard suppressed != result.suppressedInkIDs.contains(id) else {continue}
      if suppressed {result.suppressedInkIDs.insert(id)} else {result.suppressedInkIDs.remove(id)}
    }
    return result
  }
  func replacingBody(_ body:Body)->Self {
    var result=self
    if let old=self.body(sourceID:body.sourceID) {
      guard old != body else {return self}
      if old.key != body.key {result.paint[old.key]=nil}
      if old.elementID != body.elementID {result.elementSources[old.elementID]=nil}
    }
    precondition(result.elementSources[body.elementID].map{$0 == body.sourceID} ?? true)
    result.paint[body.key]=body
    if result.sourceKeys[body.sourceID] != body.key {result.sourceKeys[body.sourceID]=body.key}
    if result.elementSources[body.elementID] != body.sourceID {result.elementSources[body.elementID]=body.sourceID}
    return result
  }
  static func ==(lhs:Self,rhs:Self)->Bool {
    lhs.paint == rhs.paint && lhs.suppressedInkIDs == rhs.suppressedInkIDs
  }
  var elementIDs:Set<String> { Set(bodies.map(\.elementID)) }
  var isEmpty:Bool {paint.isEmpty}
}
