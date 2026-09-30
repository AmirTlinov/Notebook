import NotebookCore
import Observation
import UIKit
import SwiftUI
import XCTest
@testable import Notebook

final class PagePresentationTests: XCTestCase {
  @MainActor
  func testEquivalentDecodedPagePublishesItsExactSourceToTheExistingReader() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-source-publication-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let page = PageDocument(size: .init(width: 100, height: 100), actor: UUID())
    let decoded = try JSONDecoder().decode(PageDocument.self, from: JSONEncoder().encode(page))
    XCTAssertEqual(page, decoded, "A durable value comparison alone cannot notify this replacement")
    let item = UUID(), controller = UUID(), address = NotebookPagePreparationWindow.Address(itemID: item, index: 0, root: "accepted")
    let window = NotebookPagePreparationWindow()
    defer { _ = window.stop() }
    window.addresses[address] = page.id
    window.acceptedPages([page.id: page], model: model)
    window.updatePresence(.init(boardID: UUID(), mode: .page, camera: .init(),
      viewport: .init(x: 100, y: 100), focusedItemID: item, openProgress: 1,
      selectedItemID: item, notebookPageID: page.id))
    window.retain([0], in: item, root: address.root, target: nil, targetIsLoaded: true, controllerID: controller)
    let readiness = PageTurnReadiness(activity: .init(), agentPreparationSource: .notebook {
      .init(address: address, pageID: page.id, controllerID: controller)
    }) { _ in }
    defer { readiness.retire() }
    XCTAssertTrue(readiness.acceptNotebookPage(page.id, from: window))
    let entry = try XCTUnwrap(readiness.notebookPageSource), preparations = entry.preparations
    let previous = PageSurface(page: entry.document, isCurrent: true, isInteractive: true,
      isVisible: true, onRenderReady: readiness, sourceVersion: entry.sourceVersion)
    @MainActor final class Changes { var count = 0 }
    let changes = Changes()
    func observe() {
      withObservationTracking { _ = entry.document } onChange: {
        MainActor.assumeIsolated { changes.count += 1 }
      }
    }
    observe()
    window.acceptedPages([page.id: decoded], model: model)
    XCTAssertEqual(changes.count, 1, "The mounted reader must observe exact accepted root replacement")
    XCTAssertTrue(readiness.acceptNotebookPage(page.id, from: window))
    XCTAssertTrue(readiness.notebookPageSource === entry)
    XCTAssertTrue(entry.preparations === preparations, "Rebinding does not remount the host or replace its runtime owner")
    let current = PageSurface(page: entry.document, isCurrent: true, isInteractive: true,
      isVisible: true, onRenderReady: readiness, sourceVersion: entry.sourceVersion)
    XCTAssertNotEqual(previous.sourceVersion, current.sourceVersion,
      "Child view equality must not hide the accepted source behind equivalent PageDocument values")
    XCTAssertEqual(current.page.inkSource.identity, decoded.inkSource.identity)
    XCTAssertEqual(current.page.elementSourceIdentity, decoded.elementSourceIdentity)
    XCTAssertEqual(previous.page.elementSourceIdentity, page.elementSourceIdentity,
      "An old installation callback retains its original immutable source")
    observe()
    window.acceptedPages([page.id: decoded], model: model)
    XCTAssertEqual(changes.count, 1, "Unchanged accepted roots do not invalidate the page")
  }

  @MainActor
  func testEquivalentDecodedPageRebindsItsInstalledGraphicsReceipt() throws {
    let actor = UUID()
    let element = AgentElement(id: "program", kind: .web,
      frame: .init(x: 0, y: 0, width: 32, height: 32), source: "installed", html: "installed")
    for elements in [[], [element]] {
      var page = PageDocument(size: .init(width: 100, height: 100), actor: actor)
      if !elements.isEmpty { XCTAssertTrue(page.replaceElements(elements, actor: actor)) }
      let decoded = try JSONDecoder().decode(PageDocument.self, from: JSONEncoder().encode(page))
      XCTAssertEqual(decoded, page)
      XCTAssertNotEqual(decoded.elementSourceIdentity, page.elementSourceIdentity)
      let ledger = AgentOverlayReadiness(), surface = PageSurfaceReadiness()
      surface.recordInk(.init(pageID: page.id, stamp: page.drawingStamp))
      func prepare(_ value: PageDocument) -> UUID {
        ledger.prepare(sourceIdentity: value.elementSourceIdentity, elements: value.elements,
          pageSize: value.size, erasure: .init(pageID: value.id, stamp: value.drawingStamp, erasures: [:]),
          publish: { ready, _ in surface.recordGraphics(ready, page: value) })
      }
      let previous = prepare(page)
      for element in elements { XCTAssertTrue(ledger.record(element, ready: true)) }
      ledger.publish()
      XCTAssertTrue(surface.isReady(page))
      let rebound = prepare(decoded)
      XCTAssertNotEqual(previous, rebound, "A new source needs the existing view's publication edge")
      XCTAssertFalse(surface.isReady(decoded), "The old envelope is not this source's receipt")
      ledger.publish()
      XCTAssertTrue(surface.isReady(decoded), "Unchanged installed facts rebind without repainting or another runtime callback")
      XCTAssertEqual(prepare(decoded), rebound, "Ordinary layout must not republish a new source")
      if !elements.isEmpty {
        var changed = decoded
        XCTAssertTrue(changed.replaceElements([.init(id: element.id, kind: .web,
          frame: element.frame, source: "replacement", html: "replacement")], actor: actor))
        _ = prepare(changed); ledger.publish()
        XCTAssertFalse(surface.isReady(changed), "A changed program still needs its own installed pixels")
      }
    }
  }

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
      for child in view.subviews {
        if let found = find(child) { return found }
      }
      return nil
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
