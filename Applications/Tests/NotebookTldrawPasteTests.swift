import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
import NotebookCore
@testable import Notebook

@MainActor final class NotebookTldrawPasteTests: XCTestCase {
  static let source = #"{"schema":{"schemaVersion":2,"sequences":{}},"shapes":[{"id":"shape:a","type":"geo","parentId":"page:a","index":"a1","x":10,"y":20,"rotation":0,"props":{"geo":"triangle","w":120,"h":100,"text":"Imported triangle"}},{"id":"shape:b","type":"geo","parentId":"page:a","index":"a2","x":240,"y":20,"rotation":0,"props":{"geo":"ellipse","w":100,"h":100,"text":"Imported circle"}}],"bindings":[]}"#

  func testHTMLPasteAndOneNativeUndoOnPageAndBoard() async throws {
    let html=Data(("<div data-tldraw>"+Self.source+"</div>").utf8)
    let provider=NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier:UTType.html.identifier,visibility:.all) { completion in
      completion(html,nil); return nil
    }
    provider.registerDataRepresentation(forTypeIdentifier:UTType.plainText.identifier,visibility:.all) { completion in
      completion(Data("Labels alone must not win".utf8),nil); return nil
    }
    guard case .composition(let source) = try await NotebookClipboard.read([provider], availableSize: .init(x:834,y:1194)) else { return XCTFail("Structure must win over its text representation") }
    let fragment=try NotebookTldrawImport.prepare(source:source,namespace:UUID())
    XCTAssertEqual(fragment.elements.count,2)
    for onBoard in [false,true] {
      let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-tldraw-\(UUID())")
      let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
      retainNotebookUntilTeardown(model,removing:root)
      await model.start(pageSize:NotebookAppModel.defaultPageSize)
      let workspace=try XCTUnwrap(model.workspace), pageID=try XCTUnwrap(workspace.selectedPageID)
      let center=try XCTUnwrap(model.boardHierarchy?.focusedCenter(of:workspace.selectedItemID,in:workspace.rootBoardID))
      model.updatePresence(.init(boardID:workspace.rootBoardID,mode:onBoard ? .board : .page,
        camera:.init(center:center,scale:1),viewport:.init(x:834,y:1194),focusedItemID:onBoard ? nil : workspace.selectedItemID,
        openProgress:onBoard ? 0 : 1,notebookPageID:onBoard ? nil : pageID),settled:true)
      let destination=try XCTUnwrap(model.pasteDestination)
      let saved=await model.insertClipboardFragment(fragment,at:destination)
      XCTAssertTrue(saved)
      await model.reloadExternalChanges()?.value
      func ids() throws -> Set<String> {
        if onBoard { return Set(try model.store.readSceneWindow(boardID:workspace.rootBoardID,bounds:.init(origin:center.offsetBy(x:-1000,y:-1000),width:2000,height:2000)).boards.first!.board.elements.map(\.id)) }
        return Set(try model.store.loadPage(pageID).elements.map(\.id))
      }
      XCTAssertTrue(try ids().isSuperset(of:fragment.elements.map(\.id)))
      model.undoLastSurfaceAction()
      let finished=await model.finishPendingPersistence()
      XCTAssertTrue(finished)
      XCTAssertTrue(try ids().isDisjoint(with:fragment.elements.map(\.id)))
    }
  }
}
