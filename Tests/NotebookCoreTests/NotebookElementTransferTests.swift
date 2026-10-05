import Foundation
import Testing
@testable import NotebookCore

@Suite("Complete addressed selection transfer")
struct NotebookElementTransferTests {
  private func fixture(_ body:(NotebookStore,UUID,CollaborationTarget) throws -> Void) throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let actor=UUID(),store=NotebookStore(root:root)
    let header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    try body(store,actor,.init(kind:.board,id:header.rootBoardID))
  }

  private func insert(_ ids:[String],parent:String?,store:NotebookStore,actor:UUID,target:CollaborationTarget) throws {
    let operations=try ids.enumerated().map { index,id in
      var values:[String:JSONValue]=["kind":.string(parent == nil ? "group" : "nativeText"),
        "source":.string(parent == nil ? "" : "body-\(id)"),
        "frame":try .encode(PageRect(x:Double(index)*100,y:0,width:80,height:80)),
        "worldOrigin":try .encode(WorldPoint.zero)]
      if let parent { values["parentID"] = .string(parent) }
      else { values["basis"] = try .encode(NotebookElementBasis(size:.init(x:80,y:80))) }
      return CollaborationOperation(kind:.insertElement,target:target,id:id,values:values)
    }
    _ = try store.applyNativeElementEdits(operations,summary:"Fixture",sources:ids.map { .init(target:target,id:$0) },actor:actor)
  }

  @Test func fullGroupReadIncludesChildrenOutsideAOneItemSceneWindow() throws {
    try fixture { store,actor,target in
      try insert(["whole"],parent:nil,store:store,actor:actor,target:target)
      let children=(0..<20).map { "child-\($0)" }
      try insert(children,parent:"whole",store:store,actor:actor,target:target)
      let window=try store.readSceneWindow(boardID:target.id,
        bounds:.init(origin:.zero,width:80,height:80),limit:1)
      #expect(try #require(window.boards.first).board.elements.count < children.count)
      let observed=try store.readNativeElementSource(target:target,id:"whole")
      let transfer=try store.readElementTransfer(target:target,rootIDs:["whole"],observedSources:[observed])
      #expect(Set(transfer.elements.map(\.id)) == Set(["whole"]+children))
      #expect(transfer.witness.groupChildren["whole"]?.count == children.count)
      for id in children { #expect(transfer.graph.placement(id)?.parentID == "whole") }
    }
  }

  @Test func aLateChildRejectsTheEntireCutBeforeRemovingAnyOriginal() throws {
    try fixture { store,actor,target in
      try insert(["whole"],parent:nil,store:store,actor:actor,target:target)
      try insert(["child"],parent:"whole",store:store,actor:actor,target:target)
      let transfer=try store.readElementTransfer(target:target,rootIDs:["whole"])
      try insert(["late"],parent:"whole",store:store,actor:actor,target:target)
      let cursor=try store.currentChangeCursor()
      #expect(throws:CollaborationError.self) {
        try store.applyNativeElementEdits(transfer.elements.map {
          .init(kind:.removeElement,target:target,id:$0.id)
        },summary:"Cut",sources:transfer.witness.sources,transferWitness:transfer.witness,actor:actor)
      }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.readElementChildren(target:target,parentID:"whole") == ["child","late"])
      #expect(try store.readSpatialElement(boardID:target.id,elementID:"whole") != nil)
    }
  }

  @Test func oversizedGroupRefusesWholeTransferWithoutReturningAPrefix() throws {
    try fixture { store,actor,target in
      try insert(["whole"],parent:nil,store:store,actor:actor,target:target)
      try insert((0..<32).map { "child-\($0)" },parent:"whole",store:store,actor:actor,target:target)
      let cursor=try store.currentChangeCursor()
      #expect(throws:CollaborationError.self) { try store.readElementTransfer(target:target,rootIDs:["whole"]) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.readElementChildren(target:target,parentID:"whole").count == 32)
    }
  }
}
