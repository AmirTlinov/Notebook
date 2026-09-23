import NotebookCore
import UIKit
import SwiftUI
import XCTest
@testable import Notebook

final class PagePresentationTests: XCTestCase {
  @MainActor private func receipt(_ page:PageDocument,ink:Bool,graphics:Bool)->PageSurfaceReadiness {
    let result=PageSurfaceReadiness()
    result.recordInk(ink ? .init(pageID:page.id,stamp:page.drawingStamp) : nil)
    result.recordGraphics(graphics,page:page)
    return result
  }

  @MainActor
  func testStoredInkPageOpensWithoutAnExistingPresence() async throws {
    let model = NotebookDrawingFixture.makeModel()
    retainNotebookUntilTeardown(model, removing: model.store.root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let presence = try XCTUnwrap(model.presence), page = try XCTUnwrap(model.activePage)
    XCTAssertEqual(presence.mode, .page)
    XCTAssertEqual(presence.focusedItemID, model.workspace?.selectedItemID)
    XCTAssertFalse(page.drawingData.isEmpty)
    let window = try await mountNotebookScene(model)
    XCTAssertNotNil(model.presentedItem(id: try XCTUnwrap(presence.focusedItemID),
      cohort: try XCTUnwrap(model.compositionTiles.published), presence: try XCTUnwrap(model.presence)))
    func find(_ view: UIView) -> UIView? {
      if view.accessibilityIdentifier == "paper-input" { return view }
      return view.subviews.lazy.compactMap(find).first
    }
    XCTAssertNotNil(find(window))
  }

  @MainActor
  func testColdRootInstallsTheStoredInkPageAtTheActualViewport() async throws {
    let model = NotebookDrawingFixture.makeModel()
    retainNotebookUntilTeardown(model, removing: model.store.root)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let openingStarted = ContinuousClock.now
    window.rootViewController = UIHostingController(rootView: NotebookRootView().environment(model))
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let deadline = ContinuousClock.now + .seconds(8)
    func ready() -> Bool { model.activePage.map { model.pagePresentations.isPresented($0) } == true }
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(ready(), "presence=\(String(describing: model.presence)), scenePending=\(model.scenePreparationPending), sceneFailure=\(String(describing: model.compositionTiles.failure)), published=\(model.compositionTiles.published != nil), pages=\(model.pages.keys), failure=\(model.persistenceFailure ?? "none")")
    // The 8-second diagnostic timeout above is not an acceptable UX latency.
    // Include startup, source preparation, installation and window capture.
    let image = try NotebookUXObservation.Pixels(window: window).image
    try await assertUX("cold-notebook-installed", since: openingStarted,
      budget: NotebookUXObservation.coldOpening, window: window) { ready() }
    let shot = XCTAttachment(image: image); shot.name = "cold-notebook-shown"; shot.lifetime = .keepAlways; add(shot)
  }

  @MainActor
  func testInactiveOpeningWaitsForForegroundThenPresentsThePageAndPreparesHiddenCoverInk() async throws {
    let model = NotebookDrawingFixture.makeModel()
    retainNotebookUntilTeardown(model, removing: model.store.root)
    let index = try model.store.loadIndex(), actor = UUID()
    var ink = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
    _ = ink.append(tool: .pen, spans: [.init(surface: .cover(index.selectedItemID), samples: [
      .init(point: .init(x: 80, y: 160), timeOffset: 0, width: 6, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
      .init(point: .init(x: 660, y: 480), timeOffset: 0.1, width: 6, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    ])], actor: actor)
    try model.store.saveSpatialInk(ink)
    model.setPreparationForeground(false)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(rootView: NotebookRootView().environment(model))
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let loaded = ContinuousClock.now + .seconds(5)
    while model.loadState != .ready, ContinuousClock.now < loaded { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(model.permitsScenePreparation,
      "A system dialog or background scene cannot start a canvas that requires a foreground preparation window")
    XCTAssertNil(model.compositionTiles.published)
    model.setPreparationForeground(true)
    let deadline = ContinuousClock.now + .seconds(8)
    func ready() -> Bool { model.activePage.map { model.pagePresentations.isPresented($0) } == true }
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(ready(), "Foreground must resume the same requested scene without another camera gesture: \(model.compositionTiles.failure ?? "no diagnostic")")
    let canvas = try XCTUnwrap(model.compositionTiles.surfaceRegistry.canvas(for: .cover(index.selectedItemID)))
    XCTAssertGreaterThan(canvas.committedSourceNodeCount, 0)
    XCTAssertTrue(canvas.isStableFramePrepared)
    XCTAssertFalse(canvas.isStableFramePresented,
      "The opened page covers this privately prepared ink; preparation is not a shown cover")
  }

  @MainActor
  func testOnlyMountedCurrentReadySourceCanAcknowledgePaperAndRetirementRevokesIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-presentation-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    var page = PageDocument(size: .init(width: 100, height: 100), actor: UUID())
    let view = PagePresentationNativeView(), activity = PageTurnActivity()
    view.update(model: model, page: page, isCurrent: true, isVisible: true, readiness:receipt(page,ink:true,graphics:true), activity: activity)
    XCTAssertFalse(model.pagePresentations.isPresented(page), "Preparation is not an installed surface")
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    window.frame = .init(x: 0, y: 0, width: 300, height: 300)
    window.rootViewController = host; window.makeKeyAndVisible()
    view.frame = .init(x: 20, y: 20, width: 100, height: 100); host.view.addSubview(view)
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    XCTAssertTrue(model.pagePresentations.isPresented(page))
    activity.update(true)
    XCTAssertFalse(model.pagePresentations.isPresented(page), "A curl owns its in-flight surface")
    activity.update(false)
    for state in [(false, true, true), (true, false, true), (true, true, false)] {
      view.update(model: model, page: page, isCurrent: state.0, isVisible: state.1, readiness:receipt(page,ink:state.2,graphics:state.2), activity: activity)
      XCTAssertFalse(model.pagePresentations.isPresented(page))
    }
    view.update(model: model, page: page, isCurrent: true, isVisible: true, readiness:receipt(page,ink:true,graphics:true), activity: activity)
    view.removeFromSuperview()
    XCTAssertFalse(model.pagePresentations.isPresented(page), "A retained detached native view is not on screen")
    host.view.addSubview(view)
    XCTAssertTrue(page.replaceElements([.init(id: "new", kind: .markdown,
      frame: .init(x: 0, y: 0, width: 100, height: 40), source: "New", html: "<p>New</p>")], actor: UUID()))
    XCTAssertFalse(model.pagePresentations.isPresented(page), "Old installed pixels cannot acknowledge a changed source")
    view.update(model: model, page: page, isCurrent: true, isVisible: true, readiness:receipt(page,ink:true,graphics:true), activity: activity)
    XCTAssertTrue(model.pagePresentations.isPresented(page))
    view.uninstall()
    XCTAssertFalse(model.pagePresentations.isPresented(page), "UIKit retaining a retired owner cannot retain its proof")
  }
  @MainActor
  func testInstalledGraphicsStayHittableDuringInkButNeverBorrowAnotherSourceOrMount() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    let actor=UUID()
    var page=PageDocument(size:.init(width:100,height:100),actor:actor)
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first { $0.isKeyWindow },window=UIWindow(windowScene:scene)
    let host=UIViewController();window.rootViewController=host;window.makeKeyAndVisible()
    let view=PagePresentationNativeView(),activity=PageTurnActivity()
    view.frame = .init(x:20,y:20,width:100,height:100);host.view.addSubview(view)
    defer { view.uninstall();window.isHidden=true;window.rootViewController=nil;previous?.makeKey() }
    let state=PageSurfaceReadiness()
    func update(_ ready:Bool,graphics:Bool) {
      state.recordInk(ready ? .init(pageID:page.id,stamp:page.drawingStamp) : nil)
      state.recordGraphics(graphics,page:page)
      view.update(model:model,page:page,isCurrent:true,isVisible:true,readiness:state,activity:activity)
    }
    update(false,graphics:false)
    XCTAssertFalse(model.pagePresentations.hasInstalledGraphics(page),"Never grants hits to unshown graphics")
    update(true,graphics:true)
    XCTAssertTrue(model.pagePresentations.hasInstalledGraphics(page))
    let ink=PageInkAction(tool:.pen,samples:[.init(point:.init(x:20,y:20),timeOffset:0,width:3,opacity:1,force:1,azimuth:0,altitude:1)])
    let previousInk=PageInkPresentation(pageID:page.id,stamp:page.drawingStamp)
    let change=try page.prepareInkChange(.append(ink),stamp:try XCTUnwrap(page.drawingStamp.advanced(by:actor)))
    XCTAssertTrue(page.publishLiveInkChange(change))
    update(false,graphics:false)
    XCTAssertTrue(model.pagePresentations.hasInstalledGraphics(page),"New ink cannot revoke unchanged installed bodies")
    XCTAssertFalse(model.pagePresentations.isPresented(page),"Local hit eligibility is not a full-page receipt")
    state.recordGraphics(true,page:page)
    state.recordInk(.init(pageID:page.id,stamp:page.drawingStamp))
    XCTAssertTrue(model.pagePresentations.isPresented(page),"The native receipt is immediately queryable without another SwiftUI update")
    state.recordInk(previousInk)
    XCTAssertFalse(model.pagePresentations.isPresented(page),"An old ink callback cannot acknowledge this revision")
    state.recordInk(.init(pageID:UUID(),stamp:page.drawingStamp))
    XCTAssertFalse(model.pagePresentations.isPresented(page),"A different paper cannot acknowledge this revision")
    activity.update(true);XCTAssertFalse(model.pagePresentations.hasInstalledGraphics(page));activity.update(false)
    view.removeFromSuperview();XCTAssertFalse(model.pagePresentations.hasInstalledGraphics(page));host.view.addSubview(view)
    XCTAssertTrue(page.replaceElements([.init(id:"new",kind:.nativeText,frame:.init(x:0,y:0,width:40,height:20),source:"new",html:"")],actor:actor))
    update(false,graphics:false)
    XCTAssertFalse(model.pagePresentations.hasInstalledGraphics(page),"An old graphic source cannot acknowledge a newer one")
    update(true,graphics:true);XCTAssertTrue(model.pagePresentations.hasInstalledGraphics(page))
    page=PageDocument(size:page.size,actor:actor);update(false,graphics:false)
    XCTAssertFalse(model.pagePresentations.hasInstalledGraphics(page),"Another page cannot inherit the previous page's receipt")
    view.uninstall();update(true,graphics:true)
    XCTAssertFalse(model.pagePresentations.hasInstalledGraphics(page))
  }

  @MainActor
  func testVisibleProgramRegionComesFromThePhysicalClipAfterTheNativeCameraTransaction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-visibility-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: .init(width: 100, height: 100))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let clip = UIView(frame: .init(x: 20, y: 20, width: 50, height: 100)); clip.clipsToBounds = true
    controller.view.addSubview(clip)
    let view = PagePresentationNativeView(), page = PageDocument(size: .init(width: 100, height: 100), actor: UUID())
    view.frame = .init(x: -50, y: 0, width: 100, height: 100); clip.addSubview(view)
    let fringe=2/window.screen.scale
    let first=CGRect(x:50-fringe,y:0,width:50+fringe,height:100)
    let next=CGRect(x:0,y:0,width:50+fringe,height:100)
    var region: CGRect?
    let initialRegion = expectation(description: "First installed physical clip")
    view.onVisibleRegion = {
      region = $0
      if $0 == first { initialRegion.fulfill() }
    }
    view.update(model: model, page: page, isCurrent: false, isVisible: true, readiness:receipt(page,ink:false,graphics:false), activity: nil)
    view.scheduleVisibleRegion()
    await fulfillment(of: [initialRegion], timeout: 3)
    XCTAssertEqual(region, first, "A visible neighbouring page keeps its graphics, including the antialias fringe")
    let movedRegion = expectation(description: "Moved physical clip")
    view.onVisibleRegion = {
      region = $0
      if $0 == next { movedRegion.fulfill() }
    }
    let projection=ScenePlaneProjection(try XCTUnwrap(model.presence))
    view.viewport.observe(projection)
    model.updatePresence(projection.current,settled:false)
    XCTAssertFalse(model.permitsBackgroundPreparation)
    view.frame.origin.x = 0
    projection.didProject()
    await fulfillment(of: [movedRegion], timeout: 3)
    XCTAssertEqual(region, next)
    view.uninstall()
  }

}
