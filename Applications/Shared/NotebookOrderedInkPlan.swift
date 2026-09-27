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
  let bodies:[Body]
  let suppressedInkIDs:Set<UUID>
  init(bodies:[Body] = [],suppressedInkIDs:Set<UUID> = []) {
    precondition(Set(bodies.map(\.sourceID)).count == bodies.count)
    self.bodies=bodies.sorted{$0.key < $1.key}
    self.suppressedInkIDs=suppressedInkIDs
  }
  var elementIDs:Set<String> { Set(bodies.map(\.elementID)) }
  var isEmpty:Bool { bodies.isEmpty }
}
