import Foundation
import Testing
@testable import NotebookCore

private struct UndoFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("sequential-undo-\(UUID())")
  let actor = UUID()
  let store: NotebookStore
  let target: CollaborationTarget
  init() throws {
    store = NotebookStore(root: root)
    let (index, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
    target = .init(kind: .page, id: index.selectedPageID!)
    _ = try store.loadOrCreateSpatialInk(actor: actor)
    _ = try write(.insertElement, values: ["kind": .string("web"), "source": .string("original"),
      "frame": try .encode(PageRect(x: 10, y: 10, width: 100, height: 100))])
  }
  func write(_ kind: CollaborationOperation.Kind = .updateElement, values: [String: JSONValue],
    to store: NotebookStore? = nil) throws -> CollaborationReceipt {
    let store = store ?? self.store
    return try store.applyCollaborationAction(.init(summary: "Field edit", expected: [
      .init(target: target, revision: store.targetContentRevision(target: target))],
      operations: [.init(kind: kind, target: target, id: "node", values: values)]), actor: actor)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test("Последовательная отмена восстанавливает авторство поля после открытия SQLite заново")
func sequentialUndoRestoresFieldOwnership() throws {
  let f = try UndoFixture(); defer { f.clean() }
  let a = try f.write(values: ["css": .string("A")])
  let b = try f.write(values: ["css": .string("B")])
  let c = try f.write(values: ["css": .string("C")])
  let undoC = try f.store.undoCollaborationAction(c.id, actor: f.actor)
  #expect(undoC.undo?.restorations?.count == 1)
  let reopened = NotebookStore(root: f.root)
  let undoB = try reopened.undoCollaborationAction(b.id, actor: f.actor)
  #expect(undoB.undo?.preserved.isEmpty == true)
  #expect(try reopened.loadPage(f.target.id).elements[0].css == "A")
  let undoA = try NotebookStore(root: f.root).undoCollaborationAction(a.id, actor: f.actor)
  #expect(undoA.undo?.restored == 1)
  #expect(undoA.undo?.preserved.isEmpty == true)
  #expect(try reopened.loadPage(f.target.id).elements[0].css == "")
}

@Test("Независимый возврат того же значения не возвращает авторство для отмены")
func sequentialUndoRejectsIndependentABA() throws {
  let f = try UndoFixture(); defer { f.clean() }
  let a = try f.write(values: ["css": .string("A")])
  _ = try f.write(values: ["css": .string("B")])
  _ = try f.write(values: ["css": .string("A")])
  let undo = try f.store.undoCollaborationAction(a.id, actor: f.actor)
  #expect(undo.undo?.restored == 0)
  #expect(undo.undo?.preserved.count == 1)
  #expect(try f.store.loadPage(f.target.id).elements[0].css == "A")
}

@Test("Доставка обратной записи на вторую SQLite сохраняет последовательную отмену")
func sequentialUndoSurvivesReceiptReplication() throws {
  let f = try UndoFixture(); defer { f.clean() }
  let a = try f.write(values: ["css": .string("A")])
  let b = try f.write(values: ["css": .string("B")])
  let undone = try f.store.undoCollaborationAction(b.id, actor: f.actor)
  let remoteRoot = FileManager.default.temporaryDirectory.appendingPathComponent("undo-peer-\(UUID())")
  defer { try? FileManager.default.removeItem(at: remoteRoot) }
  let remote = NotebookStore(root: remoteRoot)
  _ = try remote.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194))
  _ = try remote.loadOrCreateSpatialInk(actor: UUID())
  _ = try remote.mergeCollaborationContent(f.store.collaborationContent(), actions: [a, undone])
  let inverse = try remote.undoCollaborationAction(a.id, actor: UUID())
  #expect(inverse.undo?.preserved.isEmpty == true)
  #expect(try remote.loadPage(f.target.id).elements[0].css == "")
}
