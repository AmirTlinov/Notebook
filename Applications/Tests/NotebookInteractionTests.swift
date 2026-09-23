import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class NotebookInteractionTests: XCTestCase {
  func testCoverSwipeYieldsToCameraAndCannotBecomePickupAfterPausing() async throws {
    let gate = NotebookInputGate()
    let view = NotebookInteractionTouchView(inputGate:gate)
    let touch = CoverInteractionTouch()
    _ = gate.fingerContactOwner(for:ObjectIdentifier(touch)) { .scene }
    defer { gate.endFingerContacts([ObjectIdentifier(touch)]) }
    var events:[CoverInteractionEvent] = []
    view.onLiftChanged = { events.append(.lift($0)) }
    view.onTap = { _,_ in XCTFail("Navigation is not a tap") }
    view.touchesBegan([touch],with:nil)
    XCTAssertTrue(gate.permitsSingleFingerNavigation(ObjectIdentifier(touch)))
    touch.point.x += 6
    view.touchesMoved([touch],with:nil)
    try await Task.sleep(for:.milliseconds(320))
    XCTAssertTrue(events.isEmpty)
    XCTAssertTrue(gate.permitsSingleFingerNavigation(ObjectIdentifier(touch)))
    XCTAssertTrue(view.yieldToCameraPan())
    view.touchesEnded([touch],with:nil)
    XCTAssertTrue(events.isEmpty)
  }

  func testInstalledCameraAdmitsMotionOverCoverInEitherTouchDeliveryOrder() throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first(where:\.isKeyWindow)
    for coverFirst in [false,true] {
      let window=UIWindow(windowScene:scene),root=UIViewController(),gate=NotebookInputGate()
      window.rootViewController=root;window.makeKeyAndVisible()
      let cover=NotebookInteractionTouchView(inputGate:gate);cover.frame=root.view.bounds;root.view.addSubview(cover)
      let camera=WorkspacePanView.Coordinator(isEnabled:true,inputGate:gate,onBegan:{},onChanged:{ _ in },onEnded:{ _ in },onCancelled:{})
      camera.install(on:window,inside:root.view)
      defer { cover.cancelInteraction();camera.uninstall();window.isHidden=true;previous?.makeKey() }
      let pan=try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
      let touch=CoverInteractionTouch();touch.hitView=cover
      if coverFirst { cover.touchesBegan([touch],with:nil) }
      XCTAssertTrue(camera.gestureRecognizer(pan,shouldReceive:touch))
      if !coverFirst { cover.touchesBegan([touch],with:nil) }
      touch.point.x += 12;cover.touchesMoved([touch],with:nil)
      XCTAssertTrue(camera.gestureRecognizerShouldBegin(pan),"An unpicked cover must not steal camera navigation")
      cover.touchesEnded([touch],with:nil)
    }
  }

  func testRemovedOwnerRejectsTheWholeContact() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var lifts: [Bool] = []
    var taps: [Int] = []
    view.onLiftChanged = { lifts.append($0) }
    view.onTap = { _, count in taps.append(count) }
    view.updateOwnerAvailability { false }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(320))
    view.touchesEnded([touch], with: nil)
    XCTAssertEqual(lifts, [])
    XCTAssertEqual(taps, [])
  }

  func testOwnerRestorationDoesNotReviveAnAbandonedContact() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var lifts: [Bool] = []
    view.onLiftChanged = { lifts.append($0) }
    view.touchesBegan([touch], with: nil)
    view.updateOwnerAvailability { false }
    view.updateOwnerAvailability { true }
    try await Task.sleep(for: .milliseconds(320))
    XCTAssertEqual(lifts, [])
    XCTAssertFalse(view.yieldToCameraPan(), "Removing the physical owner retired its original contact")

    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(320))
    XCTAssertEqual(lifts, [true], "A quiet hold picks up before the first movement")
    touch.point.x += 10; view.touchesMoved([touch],with:nil)
    XCTAssertEqual(lifts, [true], "Movement continues the same pickup, without a second lift")
    view.cancelInteraction()
    XCTAssertEqual(lifts, [true, false])
  }

  func testOwnerRemovalReleasesAnExistingLiftAfterTheRepresentableUpdate() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var events: [CoverInteractionEvent] = []
    view.onLiftChanged = { events.append(.lift($0)) }
    view.onTranslationEnded = { events.append(.end($0)) }
    view.onCancelled = { events.append(.cancel) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(320))
    touch.point.x += 70
    view.touchesMoved([touch], with: nil)
    XCTAssertEqual(events, [.lift(true)])

    view.updateOwnerAvailability { false }
    XCTAssertEqual(events, [.lift(true)], "updateUIView must not mutate SwiftUI state synchronously")
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(events, [.lift(true), .cancel, .lift(false)])
    XCTAssertFalse(view.yieldToCameraPan(), "Cancellation already released its native contact")
    XCTAssertEqual(events.count, 3)
  }

  func testFingerEndingBeforeDeferredCancellationCompletesTheLiftExactlyOnce() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var events: [CoverInteractionEvent] = []
    var taps = 0
    view.onLiftChanged = { events.append(.lift($0)) }
    view.onTranslationEnded = { events.append(.end($0)) }
    view.onCancelled = { events.append(.cancel) }
    view.onTap = { _, _ in taps += 1 }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(320))
    touch.point.x += 70
    view.touchesMoved([touch], with: nil)
    view.updateOwnerAvailability { false }
    view.touchesEnded([touch], with: nil)
    XCTAssertEqual(events, [.lift(true), .cancel, .lift(false)])
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(events.count, 3)
    XCTAssertEqual(taps, 0, "A cancelled lifted contact cannot become a tap")
  }

  func testACompletedLiftCommitsItsMeasuredTranslation() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var events: [CoverInteractionEvent] = []
    view.onLiftChanged = { events.append(.lift($0)) }
    view.onTranslationEnded = { events.append(.end($0)) }
    view.onCancelled = { events.append(.cancel) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(320))
    touch.point.x += 70
    touch.point.y -= 20
    view.touchesMoved([touch], with: nil)
    XCTAssertFalse(view.yieldToCameraPan(), "An admitted drag owns its finger until drop")
    view.touchesEnded([touch], with: nil)
    XCTAssertEqual(events, [.lift(true), .end(.init(width: 70, height: -20)), .lift(false)])
  }

  func testUIKitCancellationDropsOnlyTheManipulationPreview() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var events: [CoverInteractionEvent] = []
    view.onLiftChanged = { events.append(.lift($0)) }
    view.onTranslationEnded = { events.append(.end($0)) }
    view.onCancelled = { events.append(.cancel) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(320))
    touch.point.x += 70
    view.touchesMoved([touch], with: nil)
    view.touchesCancelled([touch], with: nil)
    XCTAssertEqual(events, [.lift(true), .cancel, .lift(false)])
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(events.count, 3)
  }

  func testDismantlingDefersCleanupAndKeepsItsOriginalOwnerCallbacks() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var oldEvents: [CoverInteractionEvent] = []
    var newEvents: [CoverInteractionEvent] = []
    view.onLiftChanged = { oldEvents.append(.lift($0)) }
    view.onTranslationEnded = { oldEvents.append(.end($0)) }
    view.onCancelled = { oldEvents.append(.cancel) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for:.milliseconds(320))
    touch.point.x += 10; view.touchesMoved([touch],with:nil)
    NotebookInteractionView.dismantleUIView(view, coordinator: ())
    XCTAssertEqual(oldEvents, [.lift(true)])
    view.onLiftChanged = { newEvents.append(.lift($0)) }
    view.onTranslationEnded = { newEvents.append(.end($0)) }
    view.onCancelled = { newEvents.append(.cancel) }
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(oldEvents, [.lift(true), .cancel, .lift(false)])
    XCTAssertEqual(newEvents, [])
  }

  func testCoverKeepsEmptyCornersAndErasedHolesButYieldsVisiblePaint() {
    let owner=UUID(),frame=PageRect(x:0,y:0,width:200,height:200)
    let element=SpatialElement(id:"ellipse",surface:.cover(owner),kind:.graphic,
      frame:.init(x:0,y:0,width:200,height:200),source:"",graphic:.init(shape:.ellipse,style:.init(fill:.black)),
      stamp:.init(counter:0,actor:owner))
    let graph=BoardDocument(freeItems:[],elements:[element],stamp:.init(counter:0,actor:owner)).graphicGraph()
    let cut=InkElementErasure(target:.init(elementID:element.id,frame:frame),samples:[
      .init(point:.init(x:100,y:100),timeOffset:0,width:40,opacity:1,force:1,azimuth:0,altitude:1)])
    let cover=NotebookInteractionTouchView(inputGate:NotebookInputGate())
    cover.frame = .init(x:0,y:0,width:300,height:300)
    cover.passesThrough = { point in
      NotebookAttentionProjection.pickElement(in:[element],graph:graph,erasures:[element.id:[cut]],
        appearance:{ _,graphic,layout,size,cuts in .init(graphic:graphic,layout:layout,size:size,erasures:cuts) },
        scale:1,viewport:.init(x:300,y:300),presentation:{ .init($0,placement:$1) },
        project:{ ($0.id,$0.graphic,.init(x:point.x,y:point.y)) }) != nil
    }
    XCTAssertTrue(cover.point(inside:.init(x:5,y:5),with:nil),"An ellipse's bounding box does not steal the cover")
    XCTAssertTrue(cover.point(inside:.init(x:100,y:100),with:nil),"Erased material is not a second hit owner")
    XCTAssertFalse(cover.point(inside:.init(x:50,y:100),with:nil),"The surviving object owns its painted body")

    // The background is not a fallback while canonical cut geometry is cold.
    // Nor should a far-away pending object block the rest of the cover.
    let underneath=SpatialElement(id:"underneath",surface:.cover(owner),kind:.graphic,
      frame:.init(x:0,y:0,width:300,height:300),source:"",
      graphic:.init(shape:.rectangle,style:.init(fill:.black)),stamp:.init(counter:0,actor:owner))
    let layered=BoardDocument(freeItems:[],elements:[underneath,element],stamp:.init(counter:0,actor:owner)).graphicGraph()
    var pending=false
    let cold=NotebookAttentionProjection.pickElement(in:[underneath,element],graph:layered,erasures:[element.id:[cut]],
      scale:1,viewport:.init(x:300,y:300),pending:{ pending=true },presentation:{ .init($0,placement:$1) },
      project:{ ($0.id,$0.graphic,.init(x:50,y:100)) })
    XCTAssertNil(cold);XCTAssertTrue(pending)
    pending=false
    let away=NotebookAttentionProjection.pickElement(in:[underneath,element],graph:layered,erasures:[element.id:[cut]],
      scale:1,viewport:.init(x:300,y:300),pending:{ pending=true },presentation:{ .init($0,placement:$1) },
      project:{ ($0.id,$0.graphic,.init(x:270,y:100)) })
    XCTAssertEqual(away?.id,underneath.id);XCTAssertFalse(pending)
  }

  func testCoverPassesEveryArtifactToItsOwnSelectionContact() {
    let id = UUID()
    let elements = [SpatialElementKind.nativeText, .markdown, .web].enumerated().map { index, kind in
      SpatialElement(id: "material-\(index)", surface: .cover(id), kind: kind,
        frame: .init(x: Double(index * 100), y: 0, width: 80, height: 80), source: "Material",
        stamp: .init(counter: 0, actor: UUID()))
    }
    let cover = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    cover.frame = .init(x: 0, y: 0, width: 400, height: 400)
    let graph=BoardDocument(freeItems:[],elements:elements,stamp:.init(counter:0,actor:id)).graphicGraph()
    cover.passesThrough = { point in
      NotebookAttentionProjection.pickElement(in:elements,graph:graph,scale:1,viewport:.init(x:400,y:400),
        presentation:{ .init($0,placement:$1) },project:{ ($0.id,$0.graphic,.init(x:point.x,y:point.y)) }) != nil
    }
    for x in [20.0, 120, 220] { XCTAssertFalse(cover.point(inside: .init(x: x, y: 20), with: nil)) }
    XCTAssertTrue(cover.point(inside: .init(x: 320, y: 20), with: nil))
  }
}

private enum CoverInteractionEvent: Equatable {
  case lift(Bool)
  case end(CGSize)
  case cancel
}

@MainActor
private final class CoverInteractionTouch: UITouch {
  var hitView:UIView?
  override var view:UIView? { hitView }
  var point = CGPoint(x: 100, y: 100)
  override var type: UITouch.TouchType { .direct }
  override var tapCount: Int { 1 }
  override func location(in view: UIView?) -> CGPoint { point }
}
