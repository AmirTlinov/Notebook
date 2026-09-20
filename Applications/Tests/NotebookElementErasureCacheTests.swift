import CoreGraphics
import NotebookCore
import XCTest
import SwiftUI
import UIKit
import WebKit
@testable import Notebook

@MainActor final class NotebookElementErasureCacheTests: XCTestCase {
  private let surface = SurfaceID.page(UUID())
  private let frame = PageRect(x:100,y:200,width:160,height:100)
  private let graphic = NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:4))

  private func cuts(full: Bool, count: Int = 2048) -> [InkElementErasure] {
    let samples = (0..<count).map { i in
      let angle = Double(i % 32)*2*Double.pi/32
      return SpatialInkSample(point:.init(x:100+2*cos(angle),y:250+40*sin(angle)),
        timeOffset:Double(i)/240,width:full ? 500 : 20,opacity:1,force:1,azimuth:0,altitude:1)
    }
    return [.init(target:.init(elementID:"shape",frame:frame),samples:samples)]
  }
  private func request(_ cache: NotebookElementErasureCache, _ cuts: [InkElementErasure],
    size: CGSize = .init(width:160,height:100), graphic: NotebookGraphic? = nil,
    layout: NotebookGraphicLayout? = nil) -> NotebookElementAppearance? {
    cache.appearance(surface:surface,id:"shape",graphic:graphic ?? self.graphic,layout:layout,size:size,erasures:cuts)
  }
  private func ready(_ cache: NotebookElementErasureCache, _ cuts: [InkElementErasure],
    size: CGSize = .init(width:160,height:100), graphic: NotebookGraphic? = nil,
    layout: NotebookGraphicLayout? = nil) async throws -> NotebookElementAppearance {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if let result = request(cache,cuts,size:size,graphic:graphic,layout:layout) { return result }
      try await Task.sleep(for:.milliseconds(5))
    }
    throw NSError(domain:"appearance_timeout",code:1)
  }

  func testWholeEraseUnmountsTheProgramBeforePencilLiftAndUndoRemountsIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let board = try XCTUnwrap(model.presence?.boardID)
    let element = SpatialElement(id: "erase-program", surface: .board(board), kind: .web,
      frame: .init(x: 0, y: 0, width: 160, height: 100), worldOrigin: .zero,
      source: "Animated program", html: "<svg viewBox='0 0 160 100'><circle cx='80' cy='50' r='20'><animate attributeName='r' values='10;30;10' dur='1s' repeatCount='indefinite'/></circle></svg>",
      stamp: .init(counter: 0, actor: model.actorID))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: SpatialElementContent(element: element, boardID: board).environment(model))
    window.rootViewController = host; window.makeKeyAndVisible()
    addTeardownBlock { @MainActor in
      window.isHidden = true; window.rootViewController = nil
      let stopped = await model.shutdown(); XCTAssertTrue(stopped)
      if stopped { try FileManager.default.removeItem(at: root) }
    }
    func programs(_ view: UIView) -> Int {
      (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + programs($1) }
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while programs(host.view) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(programs(host.view), 1)
    let contact = UUID()
    let cut = InkElementTarget(elementID: element.id, frame: .init(x: 0, y: 0, width: 160, height: 100), worldOrigin: .zero, wholeElement: true)
    model.updateElementErasing([.init(id: contact, surface: .board(board),
      samples: [.init(point: .zero, worldPoint: .zero, timeOffset: 0, width: 10, opacity: 1, force: 1, azimuth: 0, altitude: 1)],
      targets: [cut])], id: contact)
    let eraseDeadline = ContinuousClock.now + .seconds(1)
    while programs(host.view) > 0, ContinuousClock.now < eraseDeadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(programs(host.view), 0, "The program is dismantled, not masked or merely hidden")
    model.updateElementErasing([], id: contact)
    let undoDeadline = ContinuousClock.now + .seconds(5)
    while programs(host.view) == 0, ContinuousClock.now < undoDeadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(programs(host.view), 1)
  }

  func testWholeObjectEraseDoesNotBuildOrQueueBooleanGeometry() async throws {
    let cache = NotebookElementErasureCache()
    let cuts = [InkElementErasure(target: .init(elementID: "program", frame: frame, wholeElement: true),
      samples: cuts(full: false, count: 8192)[0].samples)]
    for _ in 0..<100 {
      let appearance = cache.appearance(surface: surface, id: "program", graphic: nil,
        layout: nil, size: .init(width: 160, height: 100), erasures: cuts)
      XCTAssertEqual(appearance?.state, .erased)
    }
    XCTAssertEqual(cache.preparationCount, 0)
    await cache.stop()
  }

  func testMeasuredPencilRouteErasesWholeProgramsAndPersistsTheirTargets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let board = try XCTUnwrap(model.presence?.boardID)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 10_000, y: 10_000))
    let initialSaved = await model.finishPendingPersistence(); XCTAssertTrue(initialSaved)
    let items = try model.store.readItemHeaders(limit: 8).map(\.item)
    let before = try model.store.loadBoard(items: items)
    var after = before
    for (index, html) in [
      "<svg viewBox='0 0 160 100'><circle cx='80' cy='50' r='20'><animate attributeName='r' values='10;30;10' dur='1s' repeatCount='indefinite'/></circle></svg>",
      "<button onclick='this.textContent=Number(this.textContent)+1'>1</button>"
    ].enumerated() {
      let element = SpatialElement(id: "program-\(index)", surface: .board(board), kind: .web,
        frame: .init(x: 0, y: 0, width: 160, height: 100), worldOrigin: .init(x: -180 + Double(index)*200, y: -50),
        source: "Program \(index)", html: html, stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(after.upsertElement(element, in: board, expected: nil, actor: model.actorID))
    }
    _ = try model.store.saveBoardEdits(before: before, after: after)
    await model.reloadExternalChanges()?.value
    let viewport = SpatialPoint(x: 834, y: 1194)
    model.updatePresence(.init(boardID: board, mode: .board, camera: .init(scale: 1), viewport: viewport), settled: true)
    model.selectDrawingTool(.eraser)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.frame = .init(x: 0, y: 0, width: viewport.x, height: viewport.y)
    window.rootViewController = host; window.makeKeyAndVisible()
    addTeardownBlock { @MainActor in
      window.isHidden = true; window.rootViewController = nil
      let stopped = await model.shutdown(); XCTAssertTrue(stopped)
      if stopped { try FileManager.default.removeItem(at: root) }
    }
    func programs(_ view: UIView) -> Int {
      (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + programs($1) }
    }
    let deadline = ContinuousClock.now + .seconds(8)
    while (programs(host.view) != 2 || model.compositionTiles.isPreparing), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(programs(host.view), 2)
    for index in 0..<2 {
      let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
      let touch = ProgramEraseTouch(), event = UIEvent()
      touch.hostWindow = window
      // Four points of measured edge movement, not a covering geometric mask.
      touch.point = .init(x: viewport.x/2 - 25 + Double(index)*200, y: viewport.y/2 + 44)
      pencil.reset(); pencil.touchesBegan([touch], with: event)
      XCTAssertTrue(model.inputGate.hasActivePencil)
      touch.point.x -= 4; touch.time += 0.1; pencil.touchesMoved([touch], with: event)
      let deadline = ContinuousClock.now + .seconds(1)
      while programs(host.view) != 1-index, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertEqual(programs(host.view), 1-index, "The real contact retires only the touched program before lift")
      XCTAssertTrue(model.inputGate.hasActivePencil)
      touch.time += 0.1; pencil.touchesEnded([touch], with: event)
      let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
      let journal = try model.store.readSpatialInk(surfaces: [.board(board)])
      XCTAssertTrue(journal.elementErasures(on: .board(board))["program-\(index)"]?.contains { $0.target.wholeElement } == true)
      XCTAssertEqual(model.elementErasureCache.preparationCount, 0)
    }
    model.undoLastSurfaceAction()
    let undoDeadline = ContinuousClock.now + .seconds(5)
    while programs(host.view) != 1, ContinuousClock.now < undoDeadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(programs(host.view), 1)
  }

  func testDensePreparationYieldsMainAndReusesOneValueForPaintPickAndCamera() async throws {
    let cache = NotebookElementErasureCache(), cuts = cuts(full:false,count:8192)
    let start = ContinuousClock.now
    for _ in 0..<30 { XCTAssertNil(request(cache,cuts)) }
    XCTAssertLessThan(start.duration(to:.now),.milliseconds(100),"No boolean geometry in a synchronous UI request")
    XCTAssertEqual(cache.preparationCount,1)
    let prepared = try await ready(cache,cuts)
    XCTAssertEqual(prepared.state,.partial)
    XCTAssertFalse(prepared.contains(.init(x:0,y:50),tolerance:6))
    XCTAssertTrue(prepared.contains(.init(x:160,y:50),tolerance:6))
    for offset in [0.0,1000,-1000] {
      let graph = NotebookGraphicGraph([.init(id:"shape",graphic:graphic,
        frame:.init(x:offset,y:offset,width:160,height:100),surface:surface,shown:true)])
      let reused = try XCTUnwrap(request(cache,cuts,layout:graph.resolve("shape").layout))
      XCTAssertTrue(reused.mask === prepared.mask)
      XCTAssertTrue(reused.remaining === prepared.remaining)
    }
    XCTAssertEqual(cache.preparationCount,1,"Translation is not a content revision")
    await cache.stop()
  }

  func testNewEraseResizeStyleAndUndoNeverReturnAnOldProjection() async throws {
    let cache = NotebookElementErasureCache(), full = cuts(full:true), partial = cuts(full:false)
    XCTAssertNil(request(cache,full))
    XCTAssertNil(request(cache,partial),"Supersede pending full erase")
    let result = try await ready(cache,partial)
    XCTAssertEqual(result.state,.partial)
    XCTAssertEqual(cache.preparationCount,2)
    let resized = CGSize(width:320,height:200)
    XCTAssertNil(request(cache,partial,size:resized))
    let big = try await ready(cache,partial,size:resized)
    XCTAssertFalse(big.contains(.init(x:0,y:100),tolerance:6))
    XCTAssertTrue(big.contains(.init(x:320,y:100),tolerance:6))
    var filled = graphic; filled.style.fill = .black
    XCTAssertNil(request(cache,partial,size:resized,graphic:filled))
    let fill = try await ready(cache,partial,size:resized,graphic:filled)
    XCTAssertTrue(fill.contains(.init(x:160,y:100),tolerance:0))
    XCTAssertNil(request(cache,[]),"Undo to intact uses the ordinary unmasked source")
    XCTAssertNil(request(cache,full))
    let erased = try await ready(cache,full)
    XCTAssertEqual(erased.state,.erased)
    XCTAssertFalse(erased.contains(.init(x:80,y:50),tolerance:12))
    await cache.stop()
    XCTAssertNil(request(cache,partial),"Stopped model cannot restart derived work")
  }

  func testMountedSiblingsNeverEvictEachOtherAndUnloadedOwnersReleaseWork() async throws {
    let cache = NotebookElementErasureCache(), cuts = cuts(full:false,count:32)
    func value(_ i: Int) -> NotebookElementAppearance? {
      cache.appearance(surface:surface,id:"shape-\(i)",graphic:graphic,layout:nil,
        size:.init(width:160,height:100),erasures:cuts)
    }
    for i in 0..<160 { XCTAssertNil(value(i)) }
    let deadline = ContinuousClock.now + .seconds(10)
    while (0..<160).contains(where: { value($0) == nil }), ContinuousClock.now < deadline {
      try await Task.sleep(for:.milliseconds(10))
    }
    for i in 0..<160 { XCTAssertNotNil(value(i)) }
    XCTAssertEqual(cache.preparationCount,160,"A mounted workset must not churn at a cache-count threshold")
    cache.retain(pages:[:])
    XCTAssertNil(value(0),"Unloading an owner releases its derived paths")
    XCTAssertEqual(cache.preparationCount,161)
    await cache.stop()
  }

  func testQuickShapeBindingUsesTheSamePreparedCutout() async throws {
    let cache = NotebookElementErasureCache(), partial = cuts(full:false), full = cuts(full:true)
    let graph = NotebookGraphicGraph([.init(id:"shape",graphic:graphic,frame:frame,surface:surface,shown:true)])
    let fit = NotebookQuickShapeFit(frame:.init(x:260,y:250,width:50,height:1),sampleCount:2,
      connection:.init(start:.init(point:.zero),end:.init(point:.init(x:50,y:0))))
    func bind(_ cuts: [InkElementErasure]) -> NotebookQuickShapeFit {
      fit.binding(in:graph,surface:surface,tolerance:6,erasures:["shape":cuts],appearance: { id,graphic,layout,size,cuts in
        cache.appearance(surface:surface,id:id,graphic:graphic,layout:layout,size:size,erasures:cuts)
      })
    }
    XCTAssertNil(bind(partial).connection?.start.binding,"Pending is not permission to bind to erased geometry")
    _ = try await ready(cache,partial)
    XCTAssertEqual(bind(partial).connection?.start.binding?.elementID,"shape")
    XCTAssertEqual(cache.preparationCount,1)
    XCTAssertNil(bind(full).connection?.start.binding)
    _ = try await ready(cache,full)
    XCTAssertNil(bind(full).connection?.start.binding)
    XCTAssertEqual(cache.preparationCount,2)
    await cache.stop()
  }

  func testConnectorLocalGeometryInvalidatesButOwnerTranslationDoesNot() async throws {
    let cache = NotebookElementErasureCache()
    var line = NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.init(x:0,y:0)),end:.init(point:.init(x:140,y:80))))
    func layout(_ graphic: NotebookGraphic, offset: Double = 0) throws -> NotebookGraphicLayout {
      let graph = NotebookGraphicGraph([.init(id:"shape",graphic:graphic,
        frame:.init(x:offset,y:offset,width:160,height:100),surface:surface,shown:true)])
      return try XCTUnwrap(graph.resolve("shape").layout)
    }
    let first = try layout(line), cuts = cuts(full:false)
    let size = CGSize(width:first.frame.width,height:first.frame.height)
    _ = try await ready(cache,cuts,size:size,graphic:line,layout:first)
    let moved = try layout(line,offset:500)
    XCTAssertNotNil(request(cache,cuts,size:size,graphic:line,layout:moved))
    XCTAssertEqual(cache.preparationCount,1)
    line.connection?.bend = 30
    let changed = try layout(line)
    XCTAssertNil(request(cache,cuts,size:size,graphic:line,layout:changed))
    _ = try await ready(cache,cuts,size:size,graphic:line,layout:changed)
    XCTAssertEqual(cache.preparationCount,2)
    await cache.stop()
  }
}

/// Measured Pencil samples reach the production recognizer on a physical
/// device. This checks its native route, not the hardware stylus sensor.
@MainActor private final class ProgramEraseTouch: UITouch {
  weak var hostWindow: UIWindow?
  var point = CGPoint.zero, time: TimeInterval = 1
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { time }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func preciseLocation(in view: UIView?) -> CGPoint { view?.convert(point, from: hostWindow) ?? point }
  override func location(in view: UIView?) -> CGPoint { preciseLocation(in: view) }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
