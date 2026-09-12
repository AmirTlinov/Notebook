import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class NotebookControlRegionTests: XCTestCase {
  @MainActor
  func testNativeControlBoundsRejectSceneGesturesButKeepOutsidePencilAndCamera() throws {
    let gate = NotebookInputGate(), pencil = UUID()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible()
    let anchor = UIView(frame: host.view.bounds)
    host.view.addSubview(anchor)
    let card = NotebookControlRegionView(gate: gate)
    card.frame = .init(x: 100, y: 150, width: 300, height: 320)
    host.view.addSubview(card)
    let camera = WorkspaceGestureLayer.Coordinator(defersHorizontalMotionToPageTurn: false,
      isEnabled: true, inputGate: gate, onCamera: { _ in XCTFail("Card input must not move camera") }, onUndo: {})
    camera.install(on: window, inside: anchor)
    let pan = BoardPanView.Coordinator(isEnabled: true, itemFrames: [], inputGate: gate,
      onTap: {}, onBegan: {}, onChanged: { _ in }, onEnded: { _ in }, onCancelled: {})
    pan.install(on: window, inside: anchor)
    defer { camera.uninstall(); pan.uninstall(); card.unregister(); window.isHidden = true }
    let cameraGesture = try XCTUnwrap(window.gestureRecognizers?.first { $0 is TwoFingerPaperGestureRecognizer })
    let observer = try XCTUnwrap(window.gestureRecognizers?.first { $0 is NotebookContactObserver })
    let panGesture = try XCTUnwrap(window.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
    let touch = RegionControlTouch(); touch.source = host.view; touch.point = .init(x: 200, y: 200)
    XCTAssertFalse(camera.gestureRecognizer(cameraGesture, shouldReceive: touch))
    XCTAssertFalse(camera.gestureRecognizer(observer, shouldReceive: touch))
    XCTAssertFalse(pan.gestureRecognizer(panGesture, shouldReceive: touch))
    touch.point = .init(x: 50, y: 80)
    XCTAssertTrue(camera.gestureRecognizer(cameraGesture, shouldReceive: touch))
    XCTAssertTrue(camera.gestureRecognizer(observer, shouldReceive: touch))
    XCTAssertTrue(pan.gestureRecognizer(panGesture, shouldReceive: touch))
    gate.beginPencilAction(source: pencil)
    let generation = gate.pencilGeneration
    card.frame.origin.y = 500
    XCTAssertTrue(gate.permitsSceneContact(at: .init(x: 200, y: 200)), "Keyboard movement uses current native bounds")
    XCTAssertFalse(gate.permitsSceneContact(at: .init(x: 200, y: 550)))
    XCTAssertTrue(gate.hasActivePencil)
    XCTAssertEqual(gate.pencilGeneration, generation, "Moving or updating the card does not end outside Pencil")
    gate.endPencilAction(source: pencil)
    card.removeFromSuperview()
    XCTAssertTrue(gate.permitsSceneContact(at: .init(x: 200, y: 550)))
  }

  @MainActor
  func testControlRegionMovesToTheNewGateWithoutLeavingAnOldExclusion() throws {
    let first = NotebookInputGate(), second = NotebookInputGate()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible()
    let card = NotebookControlRegionView(gate: first)
    card.frame = .init(x: 100, y: 150, width: 300, height: 320); host.view.addSubview(card)
    defer { card.unregister(); window.isHidden = true }
    let point = CGPoint(x: 200, y: 200)
    XCTAssertFalse(first.permitsSceneContact(at: point))
    card.use(second)
    XCTAssertTrue(first.permitsSceneContact(at: point))
    XCTAssertFalse(second.permitsSceneContact(at: point))
    card.isHidden = true
    XCTAssertTrue(second.permitsSceneContact(at: point))
  }
}

private final class RegionControlTouch: UITouch {
  var point = CGPoint.zero
  weak var source: UIView?
  override var view: UIView? { source }
  override var type: UITouch.TouchType { .direct }
  override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: view?.window) ?? point }
}
