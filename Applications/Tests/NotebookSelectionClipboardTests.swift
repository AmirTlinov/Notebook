import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookSelectionClipboardTests: XCTestCase {
  func testCutRetainsItsSourceWhenSystemClipboardPublicationFails() async throws {
    let (model,pageID)=try await clipboardModel()
    let menus=NotebookContextMenus(),pasteboard=UIPasteboard.general,previous=pasteboard.items
    defer { menus.uninstall();pasteboard.items=previous }
    menus.publishClipboard={ _ in false }
    model.selectElement(.page(pageID:pageID,elementID:"first"))
    menus.copySelection(model,selection:model.selectionSession.id,cut:true)
    await menus.clipboardTask?.value
    XCTAssertNotEqual(try model.store.loadPage(pageID).element(id:"first")?.graphic?.visible,false)
    XCTAssertTrue(model.actionCue?.contains("Выделение сохранено") == true)
    XCTAssertEqual(pasteboard.items.count,previous.count)
  }

  func testExportRejectsCapturedErasureThatExceedsCurrentMaskAdmission() async throws {
    let frame=PageRect(x:0,y:0,width:100,height:100)
    let polygon:[SpatialPoint]=[.init(x:0,y:0),.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)]
    let mask=NotebookGraphicMask(operations:(0..<64).map { _ in .init(.intersect,polygon:polygon) })
    let element=AgentElement(id:"masked",kind:.graphic,frame:frame,source:"",html:"",
      graphic:.init(shape:.rectangle,mask:mask))
    let page=PageDocument(size:.init(width:834,height:1194),actor:UUID(),elements:[element])
    let measurements=InkMeasurements([.init(point:.init(x:50,y:50),timeOffset:0,
      width:4,opacity:1,force:1,azimuth:0,altitude:1)])
    let cut=InkElementErasure(target:.init(elementID:element.id,frame:frame),measurements:measurements)
    let snapshot=NotebookSelectionExport(selectionID:UUID(),surface:.page(page.id),inkRevision:nil,
      sourceChecks:[:],sources:[element],graph:page.graphicGraph(),rootOrigin:.zero,
      erasures:[element.id:[cut]])
    let fragment=try snapshot.prepare().fragment
    XCTAssertEqual(fragment.elements[0].graphic?.mask?.operations.count,65)
    XCTAssertThrowsError(try NotebookClipboard.prepareExport(fragment))
    XCTAssertEqual(page.elements[0].graphic?.mask?.operations.count,64)
  }

  func testUIKitCopyPublishesItsCapturedMaterialAfterSelectionChanges() async throws {
    let (model,pageID)=try await clipboardModel()
    let menus=NotebookContextMenus(),pasteboard=UIPasteboard.general,previous=pasteboard.items
    defer { menus.uninstall();pasteboard.items=previous }
    model.selectElement(.page(pageID:pageID,elementID:"first"))
    menus.copySelection(model,selection:model.selectionSession.id,cut:false)
    let copy=try XCTUnwrap(menus.clipboardTask)
    model.selectElement(.page(pageID:pageID,elementID:"second"))
    let selected=model.selectionSession.id
    await copy.value
    XCTAssertEqual(try clipboardFragment().elements.map(\.id),["first"])
    XCTAssertEqual(model.selectionSession.id,selected,"Copy neither follows nor replaces the newer selection")
  }

  func testUIKitNewerCopyIsTheOnlyClipboardPublicationOwner() async throws {
    let (model,pageID)=try await clipboardModel()
    let menus=NotebookContextMenus(),pasteboard=UIPasteboard.general,previous=pasteboard.items
    defer { menus.uninstall();pasteboard.items=previous }
    model.selectElement(.page(pageID:pageID,elementID:"first"))
    menus.copySelection(model,selection:model.selectionSession.id,cut:false)
    let older=try XCTUnwrap(menus.clipboardTask)
    model.selectElement(.page(pageID:pageID,elementID:"second"))
    menus.copySelection(model,selection:model.selectionSession.id,cut:false)
    let newer=try XCTUnwrap(menus.clipboardTask)
    await newer.value;await older.value
    XCTAssertEqual(try clipboardFragment().elements.map(\.id),["second"])
    XCTAssertNil(menus.clipboardTask)
  }

  func testUIKitCutRejectsChangedSourceWithoutWritingClipboardOrDeletingMaterial() async throws {
    let (model,pageID)=try await clipboardModel(),barrier=ExportBarrier()
    let menus=NotebookContextMenus(clipboardExports:.init(encoder:{ try await barrier.encode($0) }))
    let pasteboard=UIPasteboard.general,previous=pasteboard.items
    defer { Task { await barrier.release() };menus.uninstall();pasteboard.items=previous }
    let sentinel="unchanged-clipboard-"+UUID().uuidString
    pasteboard.string=sentinel
    let reference=EditableElementReference.page(pageID:pageID,elementID:"first")
    model.selectElement(reference)
    let selected=model.selectionSession.id
    menus.copySelection(model,selection:selected,cut:true)
    let cut=try XCTUnwrap(menus.clipboardTask)
    await barrier.waitUntilStarted()
    let page=try model.store.loadPage(pageID),target=CollaborationTarget(kind:.page,id:pageID)
    _ = try model.store.applyCollaborationAction(.init(summary:"Peer moves the captured source",
      expected:[.init(target:target,revision:page.agentStamp.revision)],operations:[
        .init(kind:.updateElement,target:target,id:reference.elementID,
          values:["frame":try .encode(PageRect(x:180,y:220,width:100,height:80))])]),actor:UUID())
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.selectionSession.id,selected,"The conflict is the source, not just a replaced selection token")
    await barrier.release();await cut.value
    XCTAssertEqual(pasteboard.string,sentinel)
    XCTAssertEqual(model.actionCue,"Выделение изменилось. Повторите вырезание.")
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
    let element=try XCTUnwrap(model.store.loadPage(pageID).element(id:"first"))
    XCTAssertEqual(element.frame.x,180)
    XCTAssertNotEqual(element.graphic?.visible,false)
  }

  func testCopyInAnotherWindowRevokesTheOlderMenuExport() async throws {
    let (model,pageID)=try await clipboardModel()
    let first=NotebookContextMenus(),second=NotebookContextMenus(),pasteboard=UIPasteboard.general,previous=pasteboard.items
    defer { first.uninstall();second.uninstall();pasteboard.items=previous }
    var olderPublications=0
    let publish=first.publishClipboard
    first.publishClipboard={ value in olderPublications += 1;return publish(value) }
    model.selectElement(.page(pageID:pageID,elementID:"first"))
    first.copySelection(model,selection:model.selectionSession.id,cut:false)
    let older=try XCTUnwrap(first.clipboardTask)
    model.selectElement(.page(pageID:pageID,elementID:"second"))
    second.copySelection(model,selection:model.selectionSession.id,cut:false)
    let newer=try XCTUnwrap(second.clipboardTask)
    first.uninstall() // An old window cannot cancel the newer window's command.
    await newer.value;await older.value
    XCTAssertEqual(olderPublications,0,"All windows share the system clipboard publication owner")
    XCTAssertEqual(try clipboardFragment().elements.map(\.id),["second"])
  }

  func testRapidCopiesJoinTheActualProducerAndOnlyTheLatestCutReservesAndPublishes() async throws {
    let (model,pageID)=try await clipboardModel(),barrier=ExportBarrier()
    let exports=NotebookClipboardExportOwner(encoder:{ try await barrier.encode($0) })
    let menus=NotebookContextMenus(clipboardExports:exports),pasteboard=UIPasteboard.general,previous=pasteboard.items
    defer { Task { await barrier.release() };menus.uninstall();pasteboard.items=previous }
    model.selectElement(.page(pageID:pageID,elementID:"first"))
    menus.copySelection(model,selection:model.selectionSession.id,cut:false)
    await barrier.waitUntilStarted()
    model.selectElement(.page(pageID:pageID,elementID:"second"))
    for _ in 0..<1_000 { menus.copySelection(model,selection:model.selectionSession.id,cut:false) }
    menus.copySelection(model,selection:model.selectionSession.id,cut:true)
    let drain=try XCTUnwrap(menus.clipboardTask)
    let before=await barrier.state()
    XCTAssertEqual(before.encodes,1,"Waiting gestures must have no source/encoder worker")
    XCTAssertTrue(before.firstLeaseAlive,"Cancellation retains the old source credit until its producer exits")
    XCTAssertThrowsError(try model.beginClipboardWork(),"A second 192 MiB source cannot enter before the actual old producer joins")
    await barrier.release()
    await drain.value
    let after=await barrier.state()
    XCTAssertEqual(after.encodes,2,"Only the latest request reaches source preparation")
    XCTAssertTrue(after.previousLeaseGoneBeforeNext,"The old source/result pins leave before the next reservation/encoder")
    XCTAssertEqual(try clipboardFragment().elements.map(\.id),["second"])
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
    let page=try model.store.loadPage(pageID)
    XCTAssertNotEqual(page.element(id:"first")?.graphic?.visible,false)
    XCTAssertEqual(page.element(id:"second")?.graphic?.visible,false,"The accepted latest Cut completes independently of its menu task")
  }

  func testWaitingCopyRefusesAnEditedSourceBeforeTakingItsSnapshot() async throws {
    let (model,pageID)=try await clipboardModel(),barrier=ExportBarrier()
    let menus=NotebookContextMenus(clipboardExports:.init(encoder:{ try await barrier.encode($0) }))
    let pasteboard=UIPasteboard.general,previous=pasteboard.items
    defer { Task { await barrier.release() };menus.uninstall();pasteboard.items=previous }
    let sentinel="queued-source-"+UUID().uuidString;pasteboard.string=sentinel
    model.selectElement(.page(pageID:pageID,elementID:"first"))
    menus.copySelection(model,selection:model.selectionSession.id,cut:false)
    await barrier.waitUntilStarted()
    model.selectElement(.page(pageID:pageID,elementID:"second"))
    let selection=model.selectionSession.id
    menus.copySelection(model,selection:selection,cut:false)
    let drain=try XCTUnwrap(menus.clipboardTask)
    var page=try model.store.loadPage(pageID)
    let changed=page.elements.map { value in
      value.id == "second" ? AgentElement(id:value.id,kind:value.kind,
        frame:.init(x:600,y:220,width:100,height:80),source:value.source,html:value.html,graphic:value.graphic) : value
    }
    XCTAssertTrue(page.replaceElements(changed,actor:UUID()));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.selectionSession.id,selection)
    await barrier.release();await drain.value
    let state=await barrier.state()
    XCTAssertEqual(state.encodes,1,"The queued intent must not adopt the edited body after its join")
    XCTAssertEqual(pasteboard.string,sentinel)
    XCTAssertTrue(model.actionCue?.contains("Выделение изменилось") == true)
  }

  func testWaitingCopyPreservesItsSystemClipboardVersionAcrossTheJoin() async throws {
    let (model,pageID)=try await clipboardModel(),barrier=ExportBarrier()
    let menus=NotebookContextMenus(clipboardExports:.init(encoder:{ try await barrier.encode($0) }))
    let pasteboard=UIPasteboard.general,previous=pasteboard.items
    defer { Task { await barrier.release() };menus.uninstall();pasteboard.items=previous }
    model.selectElement(.page(pageID:pageID,elementID:"first"))
    menus.copySelection(model,selection:model.selectionSession.id,cut:false)
    await barrier.waitUntilStarted()
    model.selectElement(.page(pageID:pageID,elementID:"second"))
    menus.copySelection(model,selection:model.selectionSession.id,cut:true)
    let drain=try XCTUnwrap(menus.clipboardTask)
    let external="external-copy-"+UUID().uuidString;pasteboard.string=external
    await barrier.release();await drain.value
    XCTAssertEqual(pasteboard.string,external)
    XCTAssertNotEqual(try model.store.loadPage(pageID).element(id:"second")?.graphic?.visible,false)
    let state=await barrier.state();XCTAssertEqual(state.encodes,1)
  }

  private actor ExportBarrier {
    private var encodes=0
    private var releaseProducer:CheckedContinuation<Void,Never>?
    private var started:CheckedContinuation<Void,Never>?
    private weak var firstLease:NotebookClipboardWorkLease?
    private var previousLeaseGoneBeforeNext=false
    func encode(_ material:NotebookSelectionExport) async throws -> NotebookClipboard.Export {
      encodes += 1
      if encodes == 1 {
        firstLease=material.workLease
        await withCheckedContinuation { continuation in
          releaseProducer=continuation;started?.resume();started=nil
        }
      } else { previousLeaseGoneBeforeNext = firstLease == nil }
      return try NotebookClipboard.prepareExport(material.prepare().fragment)
    }
    func waitUntilStarted() async {
      if releaseProducer != nil { return }
      await withCheckedContinuation { started=$0 }
    }
    func release() { releaseProducer?.resume();releaseProducer=nil }
    func state() -> (encodes:Int,firstLeaseAlive:Bool,previousLeaseGoneBeforeNext:Bool) {
      (encodes,firstLease != nil,previousLeaseGoneBeforeNext)
    }
  }

  func testSystemClipboardChangeRevokesPendingCutWithoutDeletingTheSelection() async throws {
    let (model,pageID)=try await clipboardModel()
    let menus=NotebookContextMenus(),pasteboard=UIPasteboard.general,previous=pasteboard.items
    defer { menus.uninstall();pasteboard.items=previous }
    model.selectElement(.page(pageID:pageID,elementID:"first"))
    let selection=model.selectionSession.id
    menus.copySelection(model,selection:selection,cut:true)
    let older=try XCTUnwrap(menus.clipboardTask)
    // UIKit text selection or another app can write without calling this menu.
    let newer="newer-system-copy-"+UUID().uuidString
    pasteboard.string=newer
    await older.value
    XCTAssertEqual(pasteboard.string,newer)
    XCTAssertEqual(model.selectionSession.id,selection)
    XCTAssertNotEqual(try model.store.loadPage(pageID).element(id:"first")?.graphic?.visible,false)
  }

  private func clipboardModel() async throws -> (NotebookAppModel,UUID) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    _ = await model.finishPendingPersistence()
    var page=try XCTUnwrap(model.activePage)
    let elements=["first","second"].enumerated().map { index,id in
      AgentElement(id:id,kind:.graphic,frame:.init(x:Double(index)*180+40,y:220,width:100,height:80),
        source:id,html:"",graphic:.init(shape:.rectangle))
    }
    XCTAssertTrue(page.replaceElements(elements,actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    return (model,page.id)
  }

  private func clipboardFragment() throws -> NotebookPasteFragment {
    let bytes=try XCTUnwrap(UIPasteboard.general.data(forPasteboardType:NotebookClipboard.fragmentType.identifier))
    return try JSONDecoder().decode(NotebookPasteFragment.self,from:bytes)
  }

  func testTypedExportRetains100000MeasuredSamplesUntilTheOneClipboardEncoding() async throws {
    let output=try await Task.detached(priority:.userInitiated) {
      let samples=InkMeasurements((0..<100_000).map { i in
        .init(point:.init(x:Double(i%1000)/4,y:Double(i/1000)*2),timeOffset:Double(i)/240,
          width:2,opacity:1,force:0.7,azimuth:0,altitude:1)
      },revision:UUID())
      let id=UUID(),frame=PageRect(x:50,y:60,width:300,height:300)
      let graphic=NotebookGraphic(shape:.freehand,sourceInkIDs:[id],
        freehand:.init(layers:[.init(tool:.pen,color:.black,
          measured:.init(sourceID:id,span:0,measurements:samples,frame:frame,origin:nil))]))
      let element=AgentElement(id:"measured",kind:.graphic,frame:frame,source:"",html:"",graphic:graphic)
      let page=PageDocument(size:.init(width:834,height:1194),actor:UUID(),elements:[element])
      let snapshot=NotebookSelectionExport(selectionID:UUID(),surface:.page(page.id),inkRevision:nil,
        sourceChecks:[:],sources:[element],graph:page.graphicGraph(),rootOrigin:.zero,erasures:[:],
        inkKeys:[element.id:.page(sequence:1,id:id)])
      let prepared=try snapshot.prepare().fragment
      let retained=prepared.elements[0].graphic!.freehand!.layers[0].measured!.measurements
      let encoded=try NotebookClipboard.prepareExport(prepared)
      let decoded=try JSONDecoder().decode(NotebookPasteFragment.self,from:encoded.fragment)
      return (samples.revision,retained.revision,retained.count,
        decoded.elements[0].graphic!.freehand!.layers[0].measured!.measurements.count,
        prepared.elements[0].graphic!.sourceInkIDs)
    }.value
    XCTAssertEqual(output.0,output.1,"Typed preparation shares the original body rather than JSON round-tripping it")
    XCTAssertEqual(output.2,100_000);XCTAssertEqual(output.3,100_000);XCTAssertTrue(output.4.isEmpty)
  }

  func testNativeFragmentAtPaperEdgeStaysOnItsCapturedPageAfterCut() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    _ = await model.finishPendingPersistence()
    var page=try XCTUnwrap(model.activePage)
    let element=AgentElement(id:"edge",kind:.graphic,frame:.init(x:80,y:240,width:200,height:160),
      source:"Узел +",html:"",graphic:.init(shape:.rectangle))
    XCTAssertTrue(page.replaceElements([element],actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    model.selectElement(.page(pageID:page.id,elementID:element.id))
    XCTAssertTrue(model.canExportSelection)
    var snapshot=try await model.clipboardSelectionSnapshot().materialized()
    XCTAssertTrue(model.selectionStillMatches(snapshot))
    model.endSurfaceEditing()
    XCTAssertEqual(model.selectionSession.id,snapshot.selectionID)
    XCTAssertFalse(model.selectionStillMatches(snapshot),"Ending editing revokes Cut even when context keeps the UUID")
    model.selectElement(.page(pageID:page.id,elementID:element.id))
    snapshot=try await model.clipboardSelectionSnapshot().materialized()
    model.interactiveElementFocus = .page(pageID:page.id,elementID:element.id)
    XCTAssertFalse(model.selectionStillMatches(snapshot),"An active editor owns its own text commands")
    model.interactiveElementFocus=nil
    let fragment=try snapshot.prepare().fragment.reidentified()
    model.deleteSelectedContent()
    XCTAssertFalse(model.selectionStillMatches(snapshot),"A late Cut cannot delete a replacement selection/source")
    let cut=await model.finishPendingPersistence();XCTAssertTrue(cut)
    XCTAssertEqual(try model.store.loadPage(page.id).element(id:element.id)?.graphic?.visible,false,"Native removal retains its causal source but hides all its material")
    let destination=NotebookPasteDestination(target:.init(kind:.page,id:page.id),title:"Лист",
      center:.init(x:page.size.width*0.94,y:page.size.height*0.8),
      availableSize:.init(x:page.size.width,y:page.size.height),worldOrigin:nil)
    let inserted=await model.insertClipboardFragment(fragment,at:destination)
    XCTAssertTrue(inserted,model.actionCue ?? model.persistenceFailure ?? "Paste failed")
    let saved=try model.store.loadPage(page.id)
    let visible=saved.elements.filter { $0.graphic?.visible != false }
    XCTAssertEqual(visible.count,1)
    let frame=try XCTUnwrap(visible.first).frame
    XCTAssertGreaterThanOrEqual(frame.x,0);XCTAssertGreaterThanOrEqual(frame.y,0)
    XCTAssertLessThanOrEqual(frame.x+frame.width,page.size.width)
    XCTAssertLessThanOrEqual(frame.y+frame.height,page.size.height)
    XCTAssertNotEqual(visible.first?.id,element.id)
  }

  func testExportWholeAndIndividualMemberKeepsShapeTextAndDetachedPlacement() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    _ = await model.finishPendingPersistence()
    var page=try XCTUnwrap(model.activePage)
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:100,y:120,width:400,height:300),source:"",html:"",basis:.init(size:.init(x:400,y:300)))
    let child=AgentElement(id:"child",kind:.graphic,frame:.init(x:20,y:30,width:100,height:80),source:"",html:"",graphic:.init(shape:.rectangle),parentID:whole.id)
    let text=AgentElement(id:"text",kind:.nativeText,frame:.init(x:160,y:40,width:180,height:70),source:"Оригинальный текст",html:"",parentID:whole.id)
    XCTAssertTrue(page.replaceElements([whole,child,text],actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    model.selectElement(.page(pageID:page.id,elementID:whole.id))
    XCTAssertTrue(model.canExportSelection)
    let copied=try await model.clipboardSelectionSnapshot().materialized().prepare().fragment
    XCTAssertEqual(copied.elements.count,3)
    XCTAssertEqual(copied.elements[1].frame,child.frame)
    XCTAssertEqual(copied.elements[1].parentID,whole.id)
    XCTAssertEqual(copied.elements[2].source,text.source)
    model.selectElement(.page(pageID:page.id,elementID:child.id))
    let memberSnapshot=try await model.clipboardSelectionSnapshot().materialized()
    XCTAssertNotNil(memberSnapshot.sourceChecks[.page(pageID:page.id,elementID:whole.id)],
      "A late Cut also checks the ancestor that supplied the detached pose")
    let member=try memberSnapshot.prepare().fragment
    XCTAssertEqual(member.elements.count,1);XCTAssertNil(member.elements[0].parentID)
    XCTAssertEqual(member.elements[0].frame.x,0,accuracy:1e-9);XCTAssertEqual(member.elements[0].frame.y,0,accuracy:1e-9)
    XCTAssertEqual(try model.store.loadPage(page.id).elements,[whole,child,text],"Copy never mutates source membership")
    let fragment=try copied.reidentified()
    let destination=NotebookPasteDestination(target:.init(kind:.page,id:page.id),title:"Лист",center:.init(x:450,y:650),
      availableSize:.init(x:page.size.width,y:page.size.height),worldOrigin:nil)
    let inserted=await model.insertClipboardFragment(fragment,at:destination);XCTAssertTrue(inserted)
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.loadPage(page.id).elements.count,6)
    await model.reloadExternalChanges()?.value
    model.selectElement(.page(pageID:page.id,elementID:whole.id))
    model.duplicateSelectedContent()
    let duplicated=await model.finishPendingPersistence();XCTAssertTrue(duplicated)
    await model.reloadExternalChanges()?.value
    let duplicatePage=try NotebookStore(root:root).loadPage(page.id)
    XCTAssertEqual(duplicatePage.elements.count,9)
    let clones=Array(duplicatePage.elements.suffix(3))
    XCTAssertEqual(clones[0].frame.x,whole.frame.x+24)
    XCTAssertEqual(clones[0].frame.y,whole.frame.y+24)
    XCTAssertEqual(clones[1].parentID,clones[0].id)
    XCTAssertEqual(clones[2].parentID,clones[0].id)
    XCTAssertEqual(clones[2].source,text.source)
    let receipt=try XCTUnwrap(model.store.collaborationActions(afterID:nil).first { $0.action.summary == "Дублировать содержимое" })
    model.undoCollaboration(receipt.id)
    let undone=await model.finishPendingPersistence();XCTAssertTrue(undone)
    XCTAssertEqual(try NotebookStore(root:root).loadPage(page.id).elements.count,6)
  }
}
