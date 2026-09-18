import Foundation
import Testing
@testable import NotebookCore

@Suite("Created graph ownership survives only authenticated inverse chains", .serialized)
struct NotebookElementRestorationChainTests {
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-restoration-\(UUID())")
    let actor = UUID(), human = UUID()
    var store: NotebookStore
    let target: CollaborationTarget

    init() throws {
      store = NotebookStore(root: root)
      let (index, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
      target = .init(kind: .page, id: try #require(index.selectedPageID))
      _ = try store.loadOrCreateSpatialInk(actor: actor)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func reopen() { store = NotebookStore(root: root) }

    func write(_ operations: [CollaborationOperation], native: Bool = false) throws -> CollaborationReceipt {
      let basis = try store.readBasis(targets: [target])
      let action = CollaborationAction(additionalOwners: [target], summary: "Isolated graph ownership",
        expected: basis.owners, operations: operations)
      return try native ? store.applyNativeGraphicAction(action, actor: human)
        : store.applyCollaborationAction(action, actor: actor)
    }
    func create() throws -> CollaborationReceipt {
      let values: [(String, PageRect, NotebookGraphic)] = [
        ("a", .init(x: 80, y: 80, width: 100, height: 100), .init(label: "A")),
        ("b", .init(x: 420, y: 80, width: 100, height: 100), .init(label: "B")),
        ("ab", .init(x: 220, y: 130, width: 100, height: 10), .init(shape: .connector,
          label: "Before", connection: .init(start: .init(point: .zero, binding: .init(elementID: "a")),
            end: .init(point: .init(x: 100, y: 0), binding: .init(elementID: "b")))))
      ]
      return try write(values.map { id, frame, graphic in .init(kind: .insertElement, target: target, id: id,
        values: ["kind": .string("graphic"), "source": .string(""), "frame": try .encode(frame), "graphic": try .encode(graphic)]) })
    }
    func reflow() throws -> CollaborationReceipt {
      try write([
        .init(kind: .updateElement, target: target, id: "a", values: ["frame": try .encode(PageRect(x: 250, y: 80, width: 100, height: 100))]),
        .init(kind: .updateElement, target: target, id: "b", values: ["frame": try .encode(PageRect(x: 250, y: 260, width: 100, height: 100))]),
        .init(kind: .updateElement, target: target, id: "ab", values: ["graphic": .object([
          "label": .string("a → b"), "connection": .object(["bend": .number(50), "routing": .string("curved")])])])
      ])
    }
    func humanABA() throws {
      for label in ["A human continuation", "A"] {
        _ = try write([.init(kind: .updateElement, target: target, id: "a",
          values: ["graphic": .object(["label": .string(label)])])], native: true)
      }
    }
  }

  @Test(arguments: [0, 1, 2])
  func undoCreationAfterUndoingReflowsRemovesTheUnadoptedGraph(inverses: Int) throws {
    let f = try Fixture(), created = try f.create()
    let original = try f.store.loadPage(f.target.id).elements
    for _ in 0..<inverses {
      let edited = try f.reflow()
      let undone = try f.store.undoCollaborationAction(edited.id, actor: f.actor)
      #expect(undone.undo?.preserved.isEmpty == true)
      f.reopen()
      #expect(try f.store.loadPage(f.target.id).elements == original)
    }
    _ = try f.store.undoCollaborationAction(created.id, actor: f.actor)
    #expect(try f.store.loadPage(f.target.id).elements.isEmpty)
  }

  @Test(arguments: [false, true])
  func anIndependentHumanABAIsNotLaunderedByTheReflowInverse(duringReflow: Bool) throws {
    let f = try Fixture(), created = try f.create()
    let original = try f.store.readPageElement(pageID: f.target.id, elementID: "a")
    let edited = try f.reflow()
    if duringReflow { try f.humanABA() }
    _ = try f.store.undoCollaborationAction(edited.id, actor: f.actor)
    if !duringReflow { try f.humanABA() }
    f.reopen()
    #expect(try f.store.readPageElement(pageID: f.target.id, elementID: "a") == original,
      "The same visible object does not establish original creation ownership")
    let undone = try f.store.undoCollaborationAction(created.id, actor: f.actor)
    #expect(try f.store.readPageElement(pageID: f.target.id, elementID: "a") == original)
    #expect(undone.undo?.preserved.contains { $0.path == [.field("elements"), .member("a")] } == true)
  }
}
