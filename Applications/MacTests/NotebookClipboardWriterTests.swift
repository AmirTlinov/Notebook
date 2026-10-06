import AppKit
import CryptoKit
import UniformTypeIdentifiers
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookClipboardWriterTests: XCTestCase {
  func testClipboardFragmentUsesNativeBoardWriterAndOneUndo() async {
    do { try await assertClipboardFragmentUsesNativeWriter() }
    catch { XCTFail("Runtime clipboard failed: \(error)") }
  }

  func testCopyPasteCarriesAProgramsBinaryClosureThroughTheOrdinaryWriterAndUndo() async throws {
    let base=FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-resource-\(UUID())")
    let sourceFixture=MacCommandFixture(root:base.appendingPathComponent("source"))
    let targetFixture=MacCommandFixture(root:base.appendingPathComponent("target"))
    let source=sourceFixture.model,target=targetFixture.model
    addTeardownBlock {
      if (try? FileManager.default.contentsOfDirectory(atPath:base.path))?.isEmpty == true {
        try FileManager.default.removeItem(at:base)
      }
    }
    retainNotebookUntilTeardown(source,removing:base.appendingPathComponent("source"))
    retainNotebookUntilTeardown(target,removing:base.appendingPathComponent("target"))
    try await sourceFixture.start();try await targetFixture.start()
    let sourceReady=await source.finishPendingPersistence(),targetReady=await target.finishPendingPersistence()
    XCTAssertTrue(sourceReady);XCTAssertTrue(targetReady)
    let sourceWorkspace=try XCTUnwrap(source.workspace),targetWorkspace=try XCTUnwrap(target.workspace)
    for (model,workspace) in [(source,sourceWorkspace),(target,targetWorkspace)] {
      model.updatePresence(.init(boardID:workspace.rootBoardID,mode:.board,camera:.init(),
        viewport:.init(x:834,y:1194),openProgress:0),settled:true)
    }
    let js=Data("globalThis.value=7;".utf8),wasm=Data([0,97,115,109,1,0,0,0])
    for data in [js,wasm] { try source.store.stageBlob(data:data,expectedHash:sha256(data)) }
    let package=NotebookProgramPackage(javaScript:"main.js",files:[
      .init(path:"main.js",mimeType:"text/javascript",byteCount:Int64(js.count),
        parts:[.init(sha256:sha256(js),byteCount:js.count)]),
      .init(path:"model.wasm",mimeType:"application/wasm",byteCount:Int64(wasm.count),
        parts:[.init(sha256:sha256(wasm),byteCount:wasm.count)])])
    let hash=try source.store.stageProgramPackage(package)
    let address=CollaborationTarget(kind:.board,id:sourceWorkspace.rootBoardID)
    let elements:[AgentElement]=[
      .init(id:"whole",kind:.group,frame:.init(x:0,y:0,width:300,height:200),source:"",html:"",
        basis:.init(size:.init(x:300,y:200))),
      .init(id:"program",kind:.web,frame:.init(x:10,y:10,width:180,height:120),source:"",html:"",
        programPackage:hash,state:.object(["value":.number(7)]),parentID:"whole")]
    let operations=try elements.map { element -> CollaborationOperation in
      var values=try JSONValue.encode(element).objectFields
      values.removeValue(forKey:"id");values["worldOrigin"]=try .encode(WorldPoint.zero)
      return .init(kind:.insertElement,target:address,id:element.id,values:values)
    }
    _ = try source.store.applyNativeAction(.init(summary:"Clipboard source",expected:[
      .init(target:address,revision:source.store.targetContentRevision(target:address))],operations:operations),actor:source.actorID)
    await source.reloadExternalChanges()?.value
    source.selectElement(.spatial(boardID:address.id,elementID:"whole"))
    let material=try await source.clipboardSelectionSnapshot().materialized()
    let exported=try NotebookClipboard.prepareExport(material.prepare().fragment)
    let provider=NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier:NotebookClipboard.fragmentType.identifier,visibility:.all) { complete in
      complete(exported.fragment,nil);return nil
    }
    let destination=try XCTUnwrap(target.pasteDestination)
    let read=try await target.readClipboard([provider],availableSize:destination.availableSize)
    guard case .fragment(let fragment)=read.content else { return XCTFail() }
    let inserted=await target.insertClipboardFragment(fragment,at:destination,workLease:read.workLease)
    XCTAssertTrue(inserted,target.actionCue ?? target.persistenceFailure ?? "Paste failed")
    let cold=NotebookStore(root:target.store.root)
    XCTAssertEqual(try cold.readProgramPackage(hash),package)
    XCTAssertEqual(try cold.readProgramFile(package.files[1],offset:0,maxBytes:16),wasm)
    let board=try XCTUnwrap(cold.loadBoard(items:cold.loadIndex().items).board(targetWorkspace.rootBoardID))
    XCTAssertEqual(board.elements.count,2)
    XCTAssertEqual(board.elements.first(where:{$0.programPackage != nil})?.state,.object(["value":.number(7)]))
    target.undoLastSurfaceAction()
    let finished=await target.finishPendingPersistence();XCTAssertTrue(finished)
    let undone=try XCTUnwrap(cold.loadBoard(items:cold.loadIndex().items).board(targetWorkspace.rootBoardID))
    XCTAssertTrue(undone.elements.allSatisfy { !fragment.elements.map(\.id).contains($0.id) || $0.graphic?.visible == false },
      "One ordinary Undo removes both the group and its program")
    XCTAssertEqual(try source.store.readProgramPackage(hash),package)
    XCTAssertEqual(try source.store.readElementTransfer(target:address,rootIDs:["whole"]).elements.count,2)
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func assertClipboardFragmentUsesNativeWriter() async throws {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
      completion(Data("From runtime input".utf8), nil); return nil
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root), model = fixture.model
    retainNotebookUntilTeardown(model, removing: root)
    try await fixture.start()
    let workspace = try XCTUnwrap(model.workspace)
    model.updatePresence(.init(boardID: workspace.rootBoardID, mode: .board, camera: .init(),
      viewport: .init(x: 834, y: 1194), openProgress: 0), settled: true)
    let destination = try XCTUnwrap(model.pasteDestination)
    guard case .fragment(let fragment) = try await NotebookClipboard.read([provider], availableSize: destination.availableSize) else { return XCTFail() }
    let saved = await model.insertClipboardFragment(fragment, at: destination)
    XCTAssertTrue(saved)
    let rows = try model.store.readSceneWindow(boardID: destination.target.id, bounds: .init(origin: .zero.offsetBy(x: -1000, y: -1000), width: 2000, height: 2000))
    XCTAssertTrue(rows.boards.first?.board.elements.contains { $0.id == fragment.elements[0].id } == true)
    model.undoLastSurfaceAction()
    let finished = await model.finishPendingPersistence()
    XCTAssertTrue(finished)
    let undone = try model.store.readSceneWindow(boardID: destination.target.id, bounds: .init(origin: .zero.offsetBy(x: -1000, y: -1000), width: 2000, height: 2000))
    XCTAssertFalse(undone.boards.first?.board.elements.contains { $0.id == fragment.elements[0].id } == true)
  }
}
