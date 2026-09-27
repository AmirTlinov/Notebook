import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class NotebookControlRegionTests: XCTestCase {
  @MainActor
  func testDrawnHandleAdmissionExcludesOnlyItsOwnRegion() {
    let gate = NotebookInputGate(), handle = UUID(), chrome = UUID()
    let point = CGPoint(x:20,y:20)
    gate.registerControlRegion(source:handle) { _,_ in true }
    XCTAssertFalse(gate.permitsSceneContact(at:point,kind:.finger))
    XCTAssertTrue(gate.permitsSceneContact(at:point,kind:.finger,excludingControl:handle))
    gate.registerControlRegion(source:chrome) { _,_ in true }
    XCTAssertFalse(gate.permitsSceneContact(at:point,kind:.finger,excludingControl:handle),"A handle cannot steal a menu or another control")
    gate.unregisterControlRegion(source:chrome)
    gate.bindNewContactAdmission { false }
    XCTAssertFalse(gate.permitsSceneContact(at:point,kind:.finger,excludingControl:handle))
  }

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
      isEnabled: true, inputGate: gate, onCamera: { _ in XCTFail("Card input must not move camera") }, onUndo: {}, onRedo: {})
    camera.install(on: window, inside: anchor)
    let pan = WorkspacePanView.Coordinator(isEnabled: true, inputGate: gate,
      onBegan: {}, onChanged: { _ in }, onEnded: { _ in }, onCancelled: {})
    pan.install(on: window, inside: anchor)
    defer { camera.uninstall(); pan.uninstall(); card.unregister(); window.isHidden = true }
    let cameraGesture = try XCTUnwrap(window.gestureRecognizers?.first { $0 is TwoFingerPaperGestureRecognizer })
    let redoGesture = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }
      .first { $0.numberOfTouchesRequired == 3 })
    let observer = try XCTUnwrap(window.gestureRecognizers?.first { $0 is NotebookContactObserver })
    let panGesture = try XCTUnwrap(window.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
    let touch = RegionControlTouch(); touch.source = host.view; touch.point = .init(x: 200, y: 200)
    XCTAssertFalse(camera.gestureRecognizer(cameraGesture, shouldReceive: touch))
    XCTAssertFalse(camera.gestureRecognizer(redoGesture, shouldReceive: touch))
    XCTAssertFalse(camera.gestureRecognizer(observer, shouldReceive: touch))
    XCTAssertFalse(pan.gestureRecognizer(panGesture, shouldReceive: touch))
    touch.point = .init(x: 50, y: 80)
    XCTAssertTrue(camera.gestureRecognizer(cameraGesture, shouldReceive: touch))
    XCTAssertTrue(camera.gestureRecognizer(observer, shouldReceive: touch))
    XCTAssertTrue(pan.gestureRecognizer(panGesture, shouldReceive: touch))
    gate.beginPencilAction(source: pencil)
    let generation = gate.pencilGeneration
    card.frame.origin.y = 500
    XCTAssertTrue(gate.permitsSceneContact(at: .init(x: 200, y: 200), kind: .finger), "Keyboard movement uses current native bounds")
    XCTAssertFalse(gate.permitsSceneContact(at: .init(x: 200, y: 550), kind: .finger))
    XCTAssertTrue(gate.hasActivePencil)
    XCTAssertEqual(gate.pencilGeneration, generation, "Moving or updating the card does not end outside Pencil")
    gate.endPencilAction(source: pencil)
    card.removeFromSuperview()
    XCTAssertTrue(gate.permitsSceneContact(at: .init(x: 200, y: 550), kind: .finger))
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
    XCTAssertFalse(first.permitsSceneContact(at: point, kind: .finger))
    card.use(second)
    XCTAssertTrue(first.permitsSceneContact(at: point, kind: .finger))
    XCTAssertFalse(second.permitsSceneContact(at: point, kind: .finger))
    card.isHidden = true
    XCTAssertTrue(second.permitsSceneContact(at: point, kind: .finger))
  }

  @MainActor
  func testSourceEditorBorrowsOnlyQuietHistoryGesturesFromTheWorkspaceOwner() throws {
    let gate = NotebookInputGate()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible()
    let anchor = UIView(frame: host.view.bounds); host.view.addSubview(anchor)
    let editor = SourceTextView(frame: .init(x: 100, y: 100, width: 400, height: 500))
    host.view.addSubview(editor)
    var sourceUndoCount = 0, sourceRedoCount = 0
    editor.sourceUndo = { sourceUndoCount += 1 }; editor.sourceRedo = { sourceRedoCount += 1 }
    let region = NotebookControlRegionView(gate: gate)
    region.frame = editor.frame; host.view.insertSubview(region, belowSubview: editor)
    let owner = WorkspaceGestureLayer.Coordinator(defersHorizontalMotionToPageTurn: false,
      isEnabled: true, inputGate: gate, onCamera: { _ in XCTFail("Code must not move the paper camera") },
      onUndo: { XCTFail("Code must use its accepted editor target") }, onRedo: {})
    owner.install(on: window, inside: anchor)
    defer { owner.uninstall(); region.unregister(); window.isHidden = true }
    let pair = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? TwoFingerPaperGestureRecognizer }.first)
    let redo = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? WorkspaceRedoGestureRecognizer }.first)
    let first = RegionControlTouch(), second = RegionControlTouch()
    first.source = editor; first.point = .init(x: 200, y: 200)
    second.source = editor; second.point = .init(x: 280, y: 200)
    XCTAssertTrue(owner.gestureRecognizer(pair, shouldReceive: first))
    XCTAssertTrue(owner.gestureRecognizer(pair, shouldReceive: second))
    XCTAssertTrue(owner.gestureRecognizer(redo, shouldReceive: first))
    let native = NotebookInputGate.FingerContactOwner.nativeInput(ObjectIdentifier(editor))
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: first, gate: gate), native)
    pair.touchesBegan([first, second], with: UIEvent())
    XCTAssertTrue(pair.historyTarget === editor); XCTAssertTrue(pair.isNativeHistory)
    first.point.x -= 50; second.point.x += 50
    first.sampleTime += 0.1; second.sampleTime += 0.1
    pair.touchesMoved([first, second], with: UIEvent())
    pair.touchesEnded([first, second], with: UIEvent())
    // UIKit may already reset a rejected attached recognizer to .possible.
    // Its completed native motion must not become either history or camera.
    XCTAssertNotEqual(pair.intent, .tap); XCTAssertNotEqual(pair.intent, .hold)
    XCTAssertFalse(pair.permitsUndoRepetition)
    XCTAssertEqual(sourceUndoCount, 0); XCTAssertEqual(sourceRedoCount, 0)
    XCTAssertNil(pair.cameraInput)
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: first, gate: gate), native)

    let contacts = Set([ObjectIdentifier(first), ObjectIdentifier(second)])
    gate.claimHistoryContacts(contacts)
    XCTAssertFalse(gate.hasOnlyHistoryContacts, "Generic scene history cannot steal native input")
    gate.claimHistoryContacts(contacts, nativeInput: ObjectIdentifier(editor))
    XCTAssertTrue(gate.hasOnlyHistoryContacts)
    gate.releaseHistoryContacts(contacts, nativeInput: ObjectIdentifier(editor))
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: first, gate: gate), native)
    gate.endFingerContacts(contacts)
    let other = UITextView(frame: editor.frame); host.view.addSubview(other)
    first.source = other
    XCTAssertFalse(owner.gestureRecognizer(pair, shouldReceive: first), "Other editors do not opt into document history")
  }
}

private final class RegionControlTouch: UITouch {
  var point = CGPoint.zero
  var sampleTime: TimeInterval = 1
  weak var source: UIView?
  override var view: UIView? { source }
  override var type: UITouch.TouchType { .direct }
  override var timestamp: TimeInterval { sampleTime }
  override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: view?.window) ?? point }
}
