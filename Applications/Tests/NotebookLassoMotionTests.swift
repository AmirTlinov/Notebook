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
        XCTAssertNotNil(layout.visibleFrame(mask:try XCTUnwrap(node.graphic.mask)))
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
    print("GUI295 100000 cut measurements: cold local coverage p50=\(cold[1]) ms; retained query p50=\(warm[60]) ms max=\(warm.last!) ms; immutable body, two bounded path slots, source and displayed frame costs excluded")
    XCTAssertLessThan(warm[60],cold[1])
  }

  func testMultipleSelectionControlsHaveNoConfirmationAction() throws {
    let gate=NotebookInputGate(),menus=NotebookContextMenus()
    let view=NotebookSelectionControlsView(gate:gate,contextMenus:menus)
    view.configure(selectionID:UUID(),frame:.init(x:100,y:100,width:200,height:200),subject:.elements(4),transformsSelection:true)
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window=UIWindow(windowScene:scene);window.frame = .init(x:0,y:0,width:834,height:1194)
    window.rootViewController=UIViewController();window.rootViewController!.view.addSubview(view)
    window.rootViewController!.view.addSubview(menus.view);menus.use(gate)
    view.frame=window.bounds;menus.view.frame=window.bounds
    window.makeKeyAndVisible();view.setNeedsLayout();view.layoutIfNeeded();menus.view.layoutIfNeeded()
    defer { view.uninstall();menus.uninstall();window.isHidden=true }
    func buttons(_ root:UIView)->[UIButton] { (root as? UIButton).map { [$0] } ?? root.subviews.flatMap(buttons) }
    XCTAssertTrue(buttons(window).contains { !$0.isHidden && $0.accessibilityIdentifier == "delete-graphic-selection" })
    XCTAssertFalse(buttons(window).contains { !$0.isHidden && ($0.accessibilityIdentifier == "edit-agent-element" || $0.accessibilityIdentifier == "finish-graphic-selection") })
  }
}
