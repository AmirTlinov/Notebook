import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookLassoMotionTests: XCTestCase {
  func testMovementSharesCoverageAndPublishesOnlyChangedPosesOnce() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("lasso-motion-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false,preferences:UserDefaults(suiteName:UUID().uuidString)!)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize);_ = await model.finishPendingPersistence()
    var page=try XCTUnwrap(model.activePage)
    let body=PageRect(x:100,y:100,width:200,height:160)
    let measurements=InkMeasurements((0..<512).map { i in
      .init(point:.init(x:140+Double(i%7)*0.1,y:110+Double(i%128)),timeOffset:Double(i)/240,
        width:16,opacity:1,force:1,azimuth:0,altitude:1)
    })
    let elements=(0..<4).map { i in
      AgentElement(id:"cut-\(i)",kind:.graphic,frame:body,source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(strokeWidth:3,fill:.init(red:Double(i)/4,green:0.3,blue:0.8)),
          mask:NotebookGraphicMask().capturing([.init(target:.init(elementID:"cut-\(i)",frame:body),measurements:measurements)],transform:nil)))
    }
    XCTAssertTrue(page.replaceElements(elements,actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
    var region=NotebookRegionSelection(id:UUID(),address:address,
      polygon:[.init(x:110,y:105),.init(x:220,y:105),.init(x:220,y:255),.init(x:110,y:255)],
      frame:.init(x:110,y:105,width:110,height:150),rawInk:nil,expectedInkRevision:nil,graphics:elements.map { address.reference($0.id) })
    region.materialization=try NotebookRegionMaterialization.prepare(region,graph:model.graphicGraph(page:page),snapshot:model.regionSourceSnapshot(address))
    let prepared=try XCTUnwrap(region.materialization),rect=CGRect(x:0,y:0,width:body.width,height:body.height)
    let paths=try prepared.working.map { try XCTUnwrap($0.graphic.mask).path(in:rect) }
    let remainders=prepared.outside.mapValues { $0.mask!.path(in:rect) }
    model.selectRegion(region)
    let contact=try XCTUnwrap(model.beginElementManipulation(region.reference,kind:.move))
    let startRevision=model.workingGraphicRevision(on:address.surface)
    var times:[Double]=[]
    for step in 1...120 {
      let start=ContinuousClock.now
      model.updateElementManipulation(contact,translation:.init(x:Double(step),y:Double(step)/2))
      let graph=model.graphicGraph(page:page)
      for (i,object) in prepared.working.enumerated() {
        let node=try XCTUnwrap(graph.node(object.id)),layout=try XCTUnwrap(graph.resolve(object.id).layout)
        XCTAssertTrue(try XCTUnwrap(node.graphic.mask).path(in:rect) === paths[i])
        XCTAssertNotNil(layout.selectionFrame(mask:try XCTUnwrap(node.graphic.mask)))
      }
      for (id,path) in remainders { XCTAssertTrue(graph.node(id)?.graphic.mask?.path(in:rect) === path) }
      times.append(Double(start.duration(to:.now).components.attoseconds)/1e15)
      XCTAssertEqual(model.workingGraphicRevision(on:address.surface),startRevision+UInt64(step),"One surface publication, not one per fragment")
    }
    let revision=model.workingGraphicRevision(on:address.surface)
    model.updateElementManipulation(contact,translation:.init(x:120,y:60))
    XCTAssertEqual(model.workingGraphicRevision(on:address.surface),revision,"Identical pose is not another publication")
    XCTAssertEqual(model.selectionSession.region?.materialization?.edits,prepared.edits,"Contact motion never reconstructs the command payload")
    times.sort()
    print("GUI295 lasso 4 cut fragments / 120 moves: pose+graph+bounds p50=\(times[60]) ms, max=\(times.last!) ms; 120 publications; retained exact mask identities; not frame or photon timing")
    XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:120,y:60)))
    let accepted=model.graphicGraph(page:page)
    for (id,path) in remainders {
      XCTAssertTrue(accepted.node(id)?.graphic.mask?.path(in:rect) === path,"Lift keeps the worker's prepared coverage instead of decoding a cold duplicate")
    }
    model.clearSelection();model.selectDrawingTool(.pen)
    let finished=await model.finishPendingPersistence();XCTAssertTrue(finished)
    let saved=try model.store.loadPage(page.id)
    for object in prepared.working {
      let value=try XCTUnwrap(saved.element(id:object.id),model.actionCue ?? "Missing saved lasso fragment")
      XCTAssertEqual(value.graphic,object.graphic)
      XCTAssertEqual(value.frame.x,object.frame.x+120,accuracy:1e-8)
    }
    await model.reloadExternalChanges()?.value
    let installed=try XCTUnwrap(model.activePage)
    let published=model.graphicGraph(page:installed)
    for (i,object) in prepared.working.enumerated() {
      let mask=try XCTUnwrap(published.node(object.id)?.graphic.mask)
      XCTAssertTrue(mask.path(in:rect) === paths[i],"Decoded publication must not restart the accepted fragment's coverage")
    }
    for (id,path) in remainders {
      XCTAssertTrue(published.node(id)?.graphic.mask?.path(in:rect) === path,"The outside remainder retains the same prepared source too")
    }
    // The first controls/query after retiring the draft exercise the installed
    // page, not the original page value or the warm manipulation snapshot.
    let next=try XCTUnwrap(prepared.selected.first)
    model.selectElement(next)
    let second=try XCTUnwrap(model.beginElementManipulation(next,kind:.move))
    model.updateElementManipulation(second,translation:.init(x:3,y:2))
    let index=try XCTUnwrap(prepared.working.firstIndex { $0.id == next.elementID })
    XCTAssertTrue(model.graphicGraph(page:installed).node(next.elementID)?.graphic.mask?.path(in:rect) === paths[index])
    model.cancelElementManipulation(second)
  }

  func testColdRegionRetainsItsPresentedPoseUntilTheCutMaterialIsReady() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("lasso-pending-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false,
      preferences:UserDefaults(suiteName:UUID().uuidString)!)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    var page=try XCTUnwrap(model.activePage)
    let element=AgentElement(id:"cold-cut",kind:.graphic,frame:.init(x:100,y:100,width:200,height:160),source:"",html:"",
      graphic:.init(shape:.rectangle,style:.init(strokeWidth:3,fill:.init(red:1,green:0,blue:0))))
    XCTAssertTrue(page.replaceElements([element],actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    let workspace=try XCTUnwrap(model.workspace),viewport=SpatialPoint(x:834,y:1194)
    let center=model.boardHierarchy?.focusedCenter(of:workspace.selectedItemID,in:workspace.rootBoardID) ?? .zero
    model.updatePresence(.init(boardID:workspace.rootBoardID,mode:.page,
      camera:.init(center:center,scale:WorkspaceItemGeometry.notebook.fitScale(viewport:viewport)),viewport:viewport,
      focusedItemID:workspace.selectedItemID,openProgress:1),settled:true)
    try await mountNotebookScene(model)
    let presence=try XCTUnwrap(model.presence)
    let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
    var ready=NotebookRegionSelection(id:UUID(),address:address,
      polygon:[.init(x:110,y:105),.init(x:220,y:105),.init(x:220,y:255),.init(x:110,y:255)],
      frame:.init(x:110,y:105,width:110,height:150),rawInk:nil,expectedInkRevision:nil,graphics:[address.reference(element.id)])
    ready.materialization=try NotebookRegionMaterialization.prepare(ready,graph:model.graphicGraph(page:page),
      snapshot:model.regionSourceSnapshot(address))
    let material=try XCTUnwrap(ready.materialization)
    let release=AsyncStream<NotebookRegionSelection>.makeStream(bufferingPolicy:.bufferingNewest(1))
    let preparation=Task<NotebookRegionSelection?,Error> {
      for await value in release.stream { return value }
      return nil
    }
    defer { release.continuation.finish();preparation.cancel() }
    var pending=ready;pending.materialization=nil;pending.preparation=NotebookRegionPreparation(preparation)
    model.selectRegion(pending)
    let oldControls=try XCTUnwrap(NotebookAttentionProjection.editingFrame(pending.reference,model:model,presence:presence))
    let contact=try XCTUnwrap(model.beginElementManipulation(pending.reference,kind:.move))
    let original=try XCTUnwrap(model.selectionSession.manipulation).original
    let revision=model.workingGraphicRevision(on:address.surface)
    for step in 1...5 {
      let dx=Double(step)*12,dy=Double(step)*40
      model.updateElementManipulation(contact,translation:.init(x:dx,y:dy))
      let accepted=try XCTUnwrap(model.selectionSession.manipulation)
      XCTAssertEqual(accepted.frame,original.offsetBy(dx:dx,dy:dy),"Preparation never delays or discards input")
      XCTAssertEqual(accepted.presentedFrame,original,"A pending cut must not publish empty moving controls")
      XCTAssertEqual(NotebookAttentionProjection.editingFrame(pending.reference,model:model,presence:presence),oldControls)
      XCTAssertEqual(model.graphicGraph(page:page).node(element.id)?.graphic,element.graphic,
        "The source stays whole until the moved material is available in the same publication")
      XCTAssertTrue(material.selected.allSatisfy { model.graphicGraph(page:page).node($0.elementID) == nil })
      XCTAssertEqual(model.workingGraphicRevision(on:address.surface),revision)
    }
    release.continuation.yield(ready);release.continuation.finish()
    let resolvedValue=try await preparation.value
    let resolved=try XCTUnwrap(resolvedValue)
    model.resolveRegionPreparation(resolved)
    let accepted=try XCTUnwrap(model.selectionSession.manipulation)
    XCTAssertEqual(accepted.frame,original.offsetBy(dx:60,dy:200))
    XCTAssertEqual(accepted.presentedFrame,accepted.frame)
    XCTAssertEqual(NotebookAttentionProjection.editingFrame(ready.reference,model:model,presence:presence),
      oldControls.offsetBy(dx:60*presence.camera.scale,dy:200*presence.camera.scale))
    let graph=model.graphicGraph(page:page)
    XCTAssertEqual(graph.node(element.id)?.graphic,material.outside[element.id])
    let moved=try material.placedWorking(by:.init(translationX:60,y:200),address:address)
    for object in moved {
      let node=try XCTUnwrap(graph.node(object.id))
      XCTAssertEqual(node.frame,object.frame)
      XCTAssertEqual(node.graphic,object.graphic)
      XCTAssertEqual(node.placement,object.node.placement)
    }
    XCTAssertEqual(model.workingGraphicRevision(on:address.surface),revision+1,
      "The resolved source cut and every moved fragment share one surface publication")
    model.cancelElementManipulation(contact)
  }

  func testRetainedMaskAvoidsRebuildingOneHundredThousandMeasurements() throws {
    let frame=PageRect(x:0,y:0,width:400,height:400)
    let measurements=InkMeasurements((0..<100_000).map { i in
      .init(point:.init(x:200,y:Double(i%2)*200+100),timeOffset:Double(i)/240,width:24,
        opacity:1,force:1,azimuth:0,altitude:1)
    })
    let mask=NotebookGraphicMask().capturing([.init(target:.init(elementID:"dense-cut",frame:frame),measurements:measurements)],transform:nil)
    let rect=CGRect(x:0,y:0,width:400,height:400)
    var cold:[Double]=[],warm:[Double]=[]
    for _ in 0..<3 {
      let start=ContinuousClock.now
      let fresh=NotebookGraphicMask(operations:mask.operations).path(in:rect)
      let duration=start.duration(to:.now)
      cold.append(Double(duration.components.seconds)*1000+Double(duration.components.attoseconds)/1e15)
      XCTAssertFalse(fresh.contains(.init(x:200,y:200)))
    }
    let retained=mask.path(in:rect)
    let published=try JSONDecoder().decode(NotebookGraphicMask.self,from:JSONEncoder().encode(mask))
    let handoffStart=ContinuousClock.now
    XCTAssertTrue(published.retainPreparedPaths(from:mask))
    XCTAssertTrue(published.path(in:rect) === retained,"A cold decoded 100k mask borrows the ready path without rebuilding")
    print("GUI295 100000 cut measurements: decoded publication handoff=\(handoffStart.duration(to:.now)); retained exact CGPath identity")
    for _ in 0..<120 {
      let start=ContinuousClock.now
      XCTAssertTrue(mask.path(in:rect) === retained)
      let duration=start.duration(to:.now)
      warm.append(Double(duration.components.seconds)*1000+Double(duration.components.attoseconds)/1e15)
    }
    cold.sort();warm.sort()
    let report="GUI295 100000 cut measurements: explicit complete contour p50=\(cold[1]) ms; retained export query p50=\(warm[60]) ms max=\(warm.last!) ms; not the live gesture path or displayed frame timing"
    print(report)
    let evidence=XCTAttachment(string:report);evidence.name="complete-mask-export-control";evidence.lifetime = .keepAlways;add(evidence)
    XCTAssertLessThan(warm[60],cold[1])
  }

  func testMultipleSelectionControlsHaveNoConfirmationAction() async throws {
    let gate=NotebookInputGate(),menus=NotebookContextMenus(),selection=UUID()
    let view=NotebookSelectionControlsView(gate:gate,contextMenus:menus)
    view.configure(selectionID:selection,frame:.init(x:100,y:100,width:200,height:200),subject:.elements(4),transformsSelection:true)
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous=scene.windows.first(where: \.isKeyWindow)
    let existingWindows=Set(scene.windows.map(ObjectIdentifier.init))
    let window=UIWindow(windowScene:scene);window.frame = .init(x:0,y:0,width:834,height:1194)
    window.rootViewController=UIViewController();window.rootViewController!.view.addSubview(view)
    window.rootViewController!.view.addSubview(menus.view);menus.use(gate)
    view.frame=window.bounds;menus.view.frame=window.bounds
    window.makeKeyAndVisible();view.setNeedsLayout();view.layoutIfNeeded();menus.view.layoutIfNeeded()
    defer { view.uninstall();menus.uninstall();window.isHidden=true;previous?.makeKey() }
    XCTAssertFalse(menus.hasPresentedMenu,"Selection alone installs controls, not a confirmation toolbar")
    // The registered buttons are deliberately not mounted inline. Inspect the
    // real native menu requested by a quiet hold, not those hidden source views.
    menus.requestSelectionMenu(selection,at:.init(x:200,y:200))
    XCTAssertTrue(menus.hasPresentedMenu)
    func titles(_ root:UIView)->[String] {
      guard !root.isHidden,root.alpha > 0 else { return [] }
      return (root as? UILabel).flatMap(\.text).map { [$0] } ?? root.subviews.flatMap(titles)
    }
    func displayedTitles()->Set<String> {
      let menuWindows=scene.windows.filter { $0 === window || !existingWindows.contains(ObjectIdentifier($0)) }
      return Set(menuWindows.flatMap(titles).filter { !$0.isEmpty })
    }
    let deadline=ContinuousClock.now + .seconds(2)
    while !displayedTitles().contains("Удалить выбранные фигуры"),ContinuousClock.now < deadline {
      try await Task.sleep(for:.milliseconds(10))
    }
    XCTAssertEqual(displayedTitles(),["Удалить выбранные фигуры"],
      "Multiple selection offers Delete, without an Edit or confirmation action")
  }
}
