import CoreGraphics
import UIKit
import Vision
import XCTest

@MainActor
final class DrawingResponsivenessTests: XCTestCase {
  func testTextToolEditsInlineAndPersistsOnBoard() { inlineText(onPage:false) }
  func testTextToolEditsInlineAndPersistsOnPage() { inlineText(onPage:true) }
  func testTextToolEditsInlineAtDeepBoardZoom() { inlineText(onPage:false,deepZoom:true) }

  private func inlineText(onPage: Bool, deepZoom: Bool = false) {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture"]
      + (onPage ? ["--notebook-native-graphic-page"] : [])
    launchPortraitFixture(app)
    XCTAssertTrue(app.buttons["drawing-tools-more"].waitForExistence(timeout:10))
    if deepZoom { app.pinch(withScale:0.1,velocity:-1); app.pinch(withScale:0.4,velocity:-1) }
    app.buttons["drawing-tools-more"].tap(); app.buttons["drawing-tool-text"].tap()
    let point = app.coordinate(withNormalizedOffset:.init(dx:0.55,dy:0.15))
    point.tap()
    let editor = app.textViews["native-text-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout:10),"A real text object must mount its inline editor at the tapped place")
    XCTAssertEqual(editor.frame.width,320,accuracy:4)
    XCTAssertEqual(editor.frame.height,64,accuracy:4,"Text entry keeps its explicit screen size at any board zoom")
    XCTAssertFalse(app.buttons["drawing-tool-text-save"].exists)
    XCTAssertFalse(app.textViews["drawing-tool-text-editor"].exists)
    XCTAssertLessThan(abs(editor.frame.minX-point.screenPoint.x),8)
    XCTAssertLessThan(abs(editor.frame.minY-point.screenPoint.y),8)
    editor.typeText("Inline 123\nSecond line")
    XCTAssertEqual(editor.value as? String,"Inline 123\nSecond line")
    let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "inline-text-\(onPage ? "page" : deepZoom ? "deep-board" : "board")"; shot.lifetime = .keepAlways; add(shot)
    app.buttons["pen-controls-toggle"].tap()
    app.coordinate(withNormalizedOffset:.init(dx:0.35,dy:0.60)).tap()
    XCTAssertTrue(editor.waitForNonExistence(timeout:5))
    let text = app.staticTexts["Inline 123\nSecond line"]
    XCTAssertTrue(text.waitForExistence(timeout:10),"Leaving the editor must keep the same text visible")
    app.coordinate(withNormalizedOffset:.zero).withOffset(.init(dx:text.frame.midX,dy:text.frame.midY)).doubleTap()
    XCTAssertTrue(editor.waitForExistence(timeout:5))
    XCTAssertEqual(editor.value as? String,"Inline 123\nSecond line","Reopening must read persisted source, not a modal draft")
    editor.typeText("!")
    app.coordinate(withNormalizedOffset:.init(dx:0.35,dy:0.60)).tap()
    XCTAssertTrue(app.staticTexts["Inline 123\nSecond line!"].waitForExistence(timeout:10))
  }

  func testErasedFiguresKeepOpeningAndPickingResponsive() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture",
      "--notebook-native-graphic-page","--notebook-native-erased","--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let node = app.images["Узел +"], paper = app.otherElements["paper-input"]
    XCTAssertTrue(node.waitForExistence(timeout:10)); XCTAssertTrue(paper.exists)
    for i in 0..<16 { XCTAssertTrue(app.images["Erased \(i)"].waitForNonExistence(timeout:2),"Erased \(i) must leave the published accessibility tree") }
    for _ in 0..<3 {
      node.coordinate(withNormalizedOffset:.init(dx:0.97,dy:0.5)).tap()
      XCTAssertTrue(app.buttons["delete-agent-element"].waitForExistence(timeout:2))
      // Tap removed paint, not the surviving opposite edge or a shape's interior.
      node.coordinate(withNormalizedOffset:.init(dx:0.01,dy:0.3)).tap()
      XCTAssertTrue(app.buttons["delete-agent-element"].waitForNonExistence(timeout:2))
      app.buttons["leave-nested-board"].tap()
      let cover = app.descendants(matching:.any).matching(identifier:"workspace-item-7e7a1000-0000-4000-8000-000000000002").firstMatch
      XCTAssertTrue(cover.waitForExistence(timeout:3)); cover.doubleTap()
      XCTAssertTrue(paper.waitForExistence(timeout:3)); XCTAssertTrue(node.waitForExistence(timeout:3))
      for i in 0..<16 { XCTAssertTrue(app.images["Erased \(i)"].waitForNonExistence(timeout:2),"Erased \(i) must leave the published accessibility tree") }
    }
    let proof = XCTAttachment(screenshot:app.screenshot())
    proof.name = "erased-figures-after-three-open-close-cycles"; proof.lifetime = .keepAlways; add(proof)
  }

  func testNearbyBlankTapsDeselectGraphicsOnPage() { nearbyBlankTaps(onPage:true) }
  func testNearbyBlankTapsDeselectGraphicsOnBoard() { nearbyBlankTaps(onPage:false) }

  private func nearbyBlankTaps(onPage: Bool) {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture",
      "--notebook-native-connector","--notebook-native-geometry-edit"] + (onPage ? ["--notebook-native-graphic-page"] : [])
    launchPortraitFixture(app)
    let line = app.images["Связь"], triangle = app.images["Треугольник"]
    XCTAssertTrue(line.waitForExistence(timeout:10)); XCTAssertTrue(triangle.waitForExistence(timeout:10))
    let remove = app.buttons["delete-agent-element"]
    func deselect(at point: XCUICoordinate, name: String) {
      point.tap()
      let gone = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in !remove.exists },object:nil)
      let result = XCTWaiter.wait(for:[gone],timeout:2)
      let proof = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
      proof.name = "blank-tap-\(name)-\(onPage ? "page" : "board")"; proof.lifetime = .keepAlways; add(proof)
      XCTAssertEqual(result,.completed,"Nearby blank paper must dismiss the capsule, not silently consume the tap")
    }
    line.tap(); XCTAssertTrue(remove.waitForExistence(timeout:3))
    let initial = line.frame, length = hypot(initial.width,initial.height)
    let normal = CGVector(dx:-initial.height/length,dy:initial.width/length)
    deselect(at:line.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
      .withOffset(.init(dx:normal.dx*16,dy:normal.dy*16)),name:"bend-handle")
    line.tap(); XCTAssertTrue(remove.waitForExistence(timeout:3))
    deselect(at:line.coordinate(withNormalizedOffset:.init(dx:0.25,dy:0.25))
      .withOffset(.init(dx:normal.dx*10,dy:normal.dy*10)),name:"line-body")
    triangle.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.6)).tap()
    XCTAssertTrue(remove.waitForExistence(timeout:3))
    let corner = app.descendants(matching:.any).matching(identifier:"resize-agent-element-bottomTrailing").firstMatch
    XCTAssertTrue(corner.waitForExistence(timeout:3))
    deselect(at:corner.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)).withOffset(.init(dx:16,dy:16)),name:"polygon-corner")
    XCTAssertEqual(line.frame,initial,"Deselecting must not move the line")

    line.tap(); XCTAssertTrue(remove.waitForExistence(timeout:3))
    let end = app.descendants(matching:.any).matching(identifier:"graphic-end-handle").firstMatch
    XCTAssertTrue(end.waitForExistence(timeout:3))
    let grip = end.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)).withOffset(.init(dx:4,dy:0))
    grip.press(forDuration:0.01,thenDragTo:grip.withOffset(.init(dx:30,dy:20)),withVelocity:.slow,thenHoldForDuration:0)
    let resized = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in line.frame.width > initial.width+20 },object:nil)
    XCTAssertEqual(XCTWaiter.wait(for:[resized],timeout:2),.completed,"The visible handle and a small tolerance still resize")
    XCTAssertTrue(remove.exists)
  }

  func testHollowPolygonsSelectResizeAndBindOnPage() { polygonInteraction(onPage:true) }
  func testHollowPolygonsSelectResizeAndBindOnBoard() { polygonInteraction(onPage:false) }

  private func polygonInteraction(onPage: Bool) {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture",
      "--notebook-native-connector","--notebook-native-polygons"] + (onPage ? ["--notebook-native-graphic-page"] : [])
    launchPortraitFixture(app)
    let triangle = app.images["Треугольник"], diamond = app.images["Ромб"], link = app.images["1:2"]
    XCTAssertTrue(triangle.waitForExistence(timeout:10)); XCTAssertTrue(diamond.waitForExistence(timeout:10))
    let neighbour = app.webViews.containing(.button,identifier:"Graphic scene counter").firstMatch
    let neighbourFrame = neighbour.frame
    func drag(_ point: XCUICoordinate, dx: CGFloat, dy: CGFloat) {
      point.press(forDuration:0.01,thenDragTo:point.withOffset(.init(dx:dx,dy:dy)),withVelocity:.slow,thenHoldForDuration:0)
    }
    triangle.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.6)).tap()
    let corner = app.descendants(matching:.any).matching(identifier:"resize-agent-element-bottomTrailing").firstMatch
    XCTAssertTrue(corner.waitForExistence(timeout:5),"A hollow polygon is selected by its interior, not a narrow contour")
    XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"resize-agent-element-trailingCenter").firstMatch.exists,
      "Small objects do not hide one-axis grips under the visible corners")
    let initial = triangle.frame
    drag(triangle.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.6)),dx:36,dy:24)
    XCTAssertEqual(triangle.frame.minX-initial.minX,36,accuracy:5)
    XCTAssertEqual(triangle.frame.minY-initial.minY,24,accuracy:5)
    let small = triangle.frame
    drag(corner.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)),dx:-20,dy:-16)
    XCTAssertEqual(triangle.frame.width,small.width-20,accuracy:4)
    XCTAssertEqual(triangle.frame.height,small.height-16,accuracy:4)
    drag(corner.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)),dx:128,dy:128)
    let right = app.descendants(matching:.any).matching(identifier:"resize-agent-element-trailingCenter").firstMatch
    XCTAssertTrue(right.waitForExistence(timeout:5))
    let moved = triangle.frame
    drag(right.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)),dx:48,dy:25)
    XCTAssertEqual(triangle.frame.width-moved.width,48,accuracy:5)
    XCTAssertEqual(triangle.frame.height,moved.height,accuracy:2,"A side handle changes only its own dimension")
    let bottom = app.descendants(matching:.any).matching(identifier:"resize-agent-element-bottomCenter").firstMatch
    let wide = triangle.frame
    drag(bottom.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)),dx:23,dy:32)
    XCTAssertEqual(triangle.frame.height-wide.height,32,accuracy:5)
    XCTAssertEqual(triangle.frame.width,wide.width,accuracy:2)
    let triangleFinal = triangle.frame
    let beforeLink = XCTAttachment(screenshot:app.screenshot()); beforeLink.name = "before-link-selection"; beforeLink.lifetime = .keepAlways; add(beforeLink)
    link.tap()
    let afterLink = XCTAttachment(screenshot:app.screenshot()); afterLink.name = "after-link-selection"; afterLink.lifetime = .keepAlways; add(afterLink)
    let terminal = app.descendants(matching:.any).matching(identifier:"graphic-end-handle").firstMatch
    XCTAssertTrue(terminal.waitForExistence(timeout:5))
    let handle = terminal.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
    handle.press(forDuration:0.01,thenDragTo:diamond.coordinate(withNormalizedOffset:.init(dx:0.58,dy:0.4)),withVelocity:.slow,thenHoldForDuration:0)
    let bound = link.frame, originalDiamond = diamond.frame
    drag(diamond.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.55)),dx:60,dy:35)
    XCTAssertEqual(diamond.frame.minX-originalDiamond.minX,60,accuracy:5)
    XCTAssertNotEqual(link.frame,bound,"Binding accepts the actual polygon interior and follows its node")
    XCTAssertEqual(neighbour.frame,neighbourFrame,"Shape manipulation does not move the camera or the neighbour")
    let finalLink = link.frame, finalDiamond = diamond.frame
    let proof = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
    proof.name = "polygon-controls-\(onPage ? "page" : "board")"; proof.lifetime = .keepAlways; add(proof)
    app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); launchPortraitFixture(app)
    XCTAssertTrue(triangle.waitForExistence(timeout:10)); XCTAssertTrue(link.waitForExistence(timeout:10))
    XCTAssertEqual(triangle.frame.minX,triangleFinal.minX,accuracy:3)
    XCTAssertEqual(triangle.frame.size.width,triangleFinal.size.width,accuracy:3)
    XCTAssertEqual(triangle.frame.size.height,triangleFinal.size.height,accuracy:3)
    XCTAssertEqual(diamond.frame.minX,finalDiamond.minX,accuracy:3)
    XCTAssertEqual(link.frame.midX,finalLink.midX,accuracy:3)
    app.terminate()
  }

  func testVertexRoundingAndFreeBendModesOnPage() { geometryEditing(onPage:true) }
  func testVertexRoundingAndFreeBendModesOnBoard() { geometryEditing(onPage:false) }

  func testLineEndpointControlsOnPage() { endpointControls(onPage:true) }
  func testLineEndpointControlsOnBoard() { endpointControls(onPage:false) }

  private func endpointControls(onPage: Bool) {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture",
      "--notebook-native-connector","--notebook-native-geometry-edit"] + (onPage ? ["--notebook-native-graphic-page"] : [])
    launchPortraitFixture(app)
    let line = app.images["Связь"]
    XCTAssertTrue(line.waitForExistence(timeout:10)); line.tap()
    let ends = app.buttons["graphic-ends-menu"], routing = app.buttons["graphic-routing-menu"]
    XCTAssertTrue(ends.waitForExistence(timeout:5)); XCTAssertTrue(routing.isHittable)
    XCTAssertFalse(app.buttons["graphic-geometry-mode"].exists)
    XCTAssertEqual(ends.frame.height,44); XCTAssertEqual(routing.frame.width,44)
    XCTAssertLessThan(app.buttons["element-actions-menu"].frame.maxX-app.buttons["graphic-style-menu"].frame.minX,274)
    let neighbour = app.webViews.containing(.button,identifier:"Graphic scene counter").firstMatch, neighbourFrame = neighbour.frame
    func outside() { app.coordinate(withNormalizedOffset:.init(dx:0.75,dy:0.18)).tap() }
    func proof(_ name: String) {
      let value = XCTAttachment(screenshot:app.screenshot()); value.name = name + (onPage ? "-page" : "-board")
      value.lifetime = .keepAlways; add(value)
    }
    ends.tap()
    let start = app.buttons["graphic-start-menu"], end = app.buttons["graphic-end-menu"]
    XCTAssertTrue(start.waitForExistence(timeout:3)); XCTAssertTrue(end.isHittable)
    start.tap(); XCTAssertTrue(app.buttons["Круг"].waitForExistence(timeout:3)); app.buttons["Круг"].tap()
    XCTAssertTrue(app.buttons["Круг"].waitForNonExistence(timeout:3)); XCTAssertEqual(start.value as? String,"Круг")
    end.tap(); XCTAssertTrue(app.buttons["Треугольник"].waitForExistence(timeout:3)); app.buttons["Треугольник"].tap()
    XCTAssertTrue(app.buttons["Треугольник"].waitForNonExistence(timeout:3))
    XCTAssertEqual(end.value as? String,"Треугольник"); XCTAssertEqual(start.value as? String,"Круг")
    proof("connection-ends-graphical-picker"); outside()
    XCTAssertTrue(start.waitForNonExistence(timeout:3)); XCTAssertTrue(ends.isHittable)
    routing.tap()
    let curved = app.buttons["connection-route-curved"], elbow = app.buttons["connection-route-elbow"]
    XCTAssertTrue(curved.waitForExistence(timeout:3)); curved.tap()
    XCTAssertTrue(curved.isSelected); XCTAssertEqual(routing.value as? String,"Кривая")
    proof("connection-curved-picker"); elbow.tap()
    XCTAssertTrue(elbow.isSelected); XCTAssertEqual(routing.value as? String,"Угловая")
    proof("connection-elbow-picker"); outside()
    XCTAssertTrue(curved.waitForNonExistence(timeout:3)); XCTAssertTrue(ends.isHittable)
    let bend = app.descendants(matching:.any).matching(identifier:"graphic-bend-handle").firstMatch
    XCTAssertTrue(bend.exists)
    let before = bend.frame
    let center = bend.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
    center.press(forDuration:0.01,thenDragTo:center.withOffset(.init(dx:24,dy:28)),withVelocity:.slow,thenHoldForDuration:0)
    XCTAssertEqual(bend.frame.midX-before.midX,24,accuracy:4); XCTAssertEqual(bend.frame.midY-before.midY,28,accuracy:4)
    XCTAssertEqual(neighbour.frame,neighbourFrame)
    proof("connection-compact-capsule")
    app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); launchPortraitFixture(app)
    XCTAssertTrue(line.waitForExistence(timeout:10)); line.tap()
    XCTAssertTrue(ends.waitForExistence(timeout:3)); XCTAssertEqual(routing.value as? String,"Угловая")
    ends.tap(); XCTAssertTrue(start.waitForExistence(timeout:3))
    XCTAssertEqual(start.value as? String,"Круг"); XCTAssertEqual(end.value as? String,"Треугольник")
    end.tap(); XCTAssertTrue(app.buttons["Стрелка"].waitForExistence(timeout:3)); app.buttons["Стрелка"].tap()
    XCTAssertTrue(app.buttons["Стрелка"].waitForNonExistence(timeout:3)); XCTAssertEqual(end.value as? String,"Стрелка")
    XCTAssertEqual(start.value as? String,"Круг")
    app.terminate()
  }

  private func geometryEditing(onPage: Bool) {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture",
      "--notebook-native-connector","--notebook-native-geometry-edit"] + (onPage ? ["--notebook-native-graphic-page"] : [])
    launchPortraitFixture(app)
    let triangle = app.images["Треугольник"], box = app.images["Прямоугольник"], line = app.images["Связь"]
    XCTAssertTrue(triangle.waitForExistence(timeout:10)); XCTAssertTrue(box.waitForExistence(timeout:10)); XCTAssertTrue(line.waitForExistence(timeout:10))
    let neighbour = app.webViews.containing(.button,identifier:"Graphic scene counter").firstMatch, neighbourFrame = neighbour.frame
    func handle(_ id: String) -> XCUIElement { app.descendants(matching:.any).matching(identifier:id).firstMatch }
    func mode(_ title: String) {
      let mode = app.buttons["graphic-geometry-mode"]
      XCTAssertTrue(mode.waitForExistence(timeout:3)); mode.tap()
      XCTAssertEqual(mode.value as? String,title,"One capsule button cycles the geometry mode directly")
    }
    func drag(_ element: XCUIElement, _ delta: CGVector) {
      let start = element.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
      start.press(forDuration:0.01,thenDragTo:start.withOffset(delta),withVelocity:.slow,thenHoldForDuration:0)
    }
    triangle.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.6)).tap()
    mode("Изменить вершины")
    let vertex = handle("graphic-vertex-0"), other = handle("graphic-vertex-1")
    XCTAssertTrue(vertex.waitForExistence(timeout:5)); XCTAssertFalse(handle("resize-agent-element-topLeading").exists)
    let first = vertex.frame, second = other.frame
    drag(vertex,.init(dx:42,dy:-28))
    XCTAssertEqual(vertex.frame.midX-first.midX,42,accuracy:4); XCTAssertEqual(vertex.frame.midY-first.midY,-28,accuracy:4)
    XCTAssertEqual(other.frame.midX,second.midX,accuracy:2); XCTAssertEqual(other.frame.midY,second.midY,accuracy:2)
    let changedVertex = vertex.frame
    mode("Скруглить углы")
    let radius = handle("graphic-corner-radius-handle")
    XCTAssertTrue(radius.waitForExistence(timeout:3)); XCTAssertFalse(vertex.exists)
    let pointed = app.screenshot(), triangleFrame = triangle.frame, radiusBefore = radius.frame
    drag(radius,.init(dx:0,dy:40))
    XCTAssertGreaterThan(radius.frame.midY,radiusBefore.midY+20)
    XCTAssertEqual(triangle.frame,triangleFrame)
    let rounded = app.screenshot()
    let proof = XCTAttachment(screenshot:rounded); proof.name = "rounded-vertex-\(onPage ? "page" : "board")"; proof.lifetime = .keepAlways; add(proof)
    XCTAssertGreaterThan(changedPixelShare(from:pointed,to:rounded,normalizedRect:.init(x:triangleFrame.minX/app.frame.width,y:triangleFrame.minY/app.frame.height,
      width:triangleFrame.width/app.frame.width,height:triangleFrame.height/app.frame.height)),0.001,"The actual contour changes, not just its handle")
    mode("Размер и положение")
    XCTAssertTrue(handle("resize-agent-element-bottomTrailing").waitForExistence(timeout:3))
    box.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)).tap(); mode("Изменить вершины")
    XCTAssertTrue(vertex.waitForExistence(timeout:3))
    let boxFirst = vertex.frame, boxOther = other.frame
    drag(vertex,.init(dx:32,dy:22))
    XCTAssertEqual(vertex.frame.midX-boxFirst.midX,32,accuracy:4); XCTAssertEqual(vertex.frame.midY-boxFirst.midY,22,accuracy:4)
    XCTAssertEqual(other.frame.midX,boxOther.midX,accuracy:2); XCTAssertEqual(other.frame.midY,boxOther.midY,accuracy:2)
    mode("Скруглить углы"); XCTAssertTrue(radius.waitForExistence(timeout:3)); drag(radius,.init(dx:24,dy:24))
    line.tap()
    let bend = handle("graphic-bend-handle"), start = handle("graphic-start-handle"), end = handle("graphic-end-handle")
    XCTAssertTrue(bend.waitForExistence(timeout:3))
    let bendBefore = bend.frame, startBefore = start.frame, endBefore = end.frame
    drag(bend,.init(dx:35,dy:40))
    XCTAssertEqual(bend.frame.midX-bendBefore.midX,35,accuracy:4); XCTAssertEqual(bend.frame.midY-bendBefore.midY,40,accuracy:4)
    XCTAssertEqual(start.frame.midX,startBefore.midX,accuracy:2); XCTAssertEqual(start.frame.midY,startBefore.midY,accuracy:2)
    XCTAssertEqual(end.frame.midX,endBefore.midX,accuracy:2); XCTAssertEqual(end.frame.midY,endBefore.midY,accuracy:2)
    XCTAssertEqual(neighbour.frame,neighbourFrame)
    let bendAfter = bend.frame, lineFrame = line.frame
    let final = XCTAttachment(screenshot:app.screenshot()); final.name = "geometry-modes-\(onPage ? "page" : "board")"; final.lifetime = .keepAlways; add(final)
    app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); launchPortraitFixture(app)
    XCTAssertTrue(line.waitForExistence(timeout:10)); XCTAssertEqual(line.frame.midX,lineFrame.midX,accuracy:3); XCTAssertEqual(line.frame.midY,lineFrame.midY,accuracy:3)
    // A curved line's empty bounding-box centre is not its painted contour.
    app.coordinate(withNormalizedOffset:.zero).withOffset(.init(dx:bendAfter.midX,dy:bendAfter.midY)).tap()
    XCTAssertTrue(bend.waitForExistence(timeout:3))
    XCTAssertEqual(bend.frame.midX,bendAfter.midX,accuracy:3); XCTAssertEqual(bend.frame.midY,bendAfter.midY,accuracy:3)
    triangle.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.65)).tap(); mode("Изменить вершины")
    XCTAssertTrue(vertex.waitForExistence(timeout:3)); XCTAssertEqual(vertex.frame.midX,changedVertex.midX,accuracy:3); XCTAssertEqual(vertex.frame.midY,changedVertex.midY,accuracy:3)
    app.terminate()
  }

  func testSelectionPaletteAndContextMenuStayAnchoredAndKeepThePaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture",
      "--notebook-native-connector","--notebook-native-polygons","--notebook-native-graphic-page"]
    launchPortraitFixture(app)
    let triangle = app.images["Треугольник"]
    XCTAssertTrue(triangle.waitForExistence(timeout:10))
    let paper = app.otherElements["paper-input"], paperFrame = paper.frame
    // Earlier chat-window scenarios preserve their user-chosen position. Move
    // the real companion away rather than tapping through its visible button.
    let companion = app.buttons["notebook-companion-compose"]
    XCTAssertTrue(companion.waitForExistence(timeout:5), "The scene content can publish before window chrome")
    // A previous run may already have placed it here. A zero-distance drag
    // is a tap, which opens chat instead of arranging the palette test.
    if companion.frame.intersects(triangle.frame) {
      let grip = companion.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
      grip.press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:.init(dx:0.8,dy:0.88)))
    }
    XCTAssertFalse(companion.frame.intersects(triangle.frame))
    triangle.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.6)).tap()
    let style = app.buttons["graphic-style-menu"], more = app.buttons["element-actions-menu"], remove = app.buttons["delete-agent-element"]
    XCTAssertTrue(style.waitForExistence(timeout:5)); XCTAssertTrue(style.isHittable)
    XCTAssertEqual(style.frame.midY,remove.frame.midY,accuracy:1)
    XCTAssertEqual(more.frame.midY,remove.frame.midY,accuracy:1)
    XCTAssertLessThan(more.frame.maxX-style.frame.minX,222)
    XCTAssertEqual(style.frame.height,44,accuracy:1)
    let before = triangle.frame
    let controls = XCTAttachment(screenshot:app.screenshot()); controls.name = "compact-element-controls"; controls.lifetime = .keepAlways; add(controls)
    style.tap()
    let blue = app.buttons["element-color-11"]
    XCTAssertTrue(blue.waitForExistence(timeout:5)); blue.tap()
    XCTAssertFalse(app.popovers.firstMatch.frame.intersects(triangle.frame), "The palette leaves the edited shape visible")
    XCTAssertTrue(blue.isSelected)
    app.buttons["element-width-4"].tap()
    XCTAssertTrue(app.buttons["element-width-4"].isSelected)
    app.buttons["element-dash-1"].tap()
    XCTAssertTrue(app.buttons["element-dash-1"].isSelected)
    let palette = XCTAttachment(screenshot:app.screenshot()); palette.name = "native-element-palette"; palette.lifetime = .keepAlways; add(palette)
    // Outside the popover and its arrow: UIKit dismisses without a canvas gesture.
    app.coordinate(withNormalizedOffset:.init(dx:0.8,dy:0.7)).tap()
    XCTAssertTrue(blue.waitForNonExistence(timeout:3))
    XCTAssertEqual(triangle.frame,before); XCTAssertEqual(paper.frame,paperFrame)
    more.tap()
    XCTAssertTrue(app.buttons["На задний план"].waitForExistence(timeout:3))
    let menu = XCTAttachment(screenshot:app.screenshot()); menu.name = "native-element-context-menu"; menu.lifetime = .keepAlways; add(menu)
    app.buttons["На передний план"].tap()
    XCTAssertEqual(triangle.frame,before); XCTAssertEqual(paper.frame,paperFrame)
    // The dismissed palette can be opened again; no retained dead presentation owner.
    style.tap(); XCTAssertTrue(blue.waitForExistence(timeout:3)); XCTAssertTrue(blue.isSelected)
    app.coordinate(withNormalizedOffset:.init(dx:0.8,dy:0.7)).tap()
    XCTAssertTrue(blue.waitForNonExistence(timeout:3))
    remove.tap(); XCTAssertTrue(triangle.waitForNonExistence(timeout:5))
    XCTAssertEqual(paper.frame,paperFrame)
    app.terminate()
  }

  func testNativeGraphicDragOnBoardKeepsTheLiveNeighbourAndSurvivesReopening() {
    nativeGraphicScenario(onPage: false)
  }

  func testNativeGraphicDragOnPageKeepsTheLiveNeighbourAndSurvivesReopening() {
    nativeGraphicScenario(onPage: true)
  }

  func testBoundConnectorOnBoardFollowsTheNodeAndEditsItsBendAndLabel() {
    nativeGraphicScenario(onPage:false,connected:true)
  }

  func testBoundConnectorOnPageFollowsTheNodeAndEditsItsBendAndLabel() {
    nativeGraphicScenario(onPage:true,connected:true)
  }

  func testDenseNativeDiagramKeepsAllConnectionsLiveAndTheProgramFocused() {
    nativeGraphicScenario(onPage: false, connected: true, dense: true)
  }

  private func nativeGraphicScenario(onPage: Bool, connected: Bool = false, dense: Bool = false) {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures",
      "--notebook-native-graphics-fixture"] + (onPage ? ["--notebook-native-graphic-page"] : [])
      + (connected ? ["--notebook-native-connector"] : [])
      + (dense ? ["--notebook-native-dense"] : [])
    launchPortraitFixture(app)
    let node = app.images["Узел +"]
    let neighbour = app.webViews.containing(.button, identifier: "Graphic scene counter").firstMatch
    XCTAssertTrue(node.waitForExistence(timeout: 10)); XCTAssertTrue(neighbour.waitForExistence(timeout: 10))
    neighbour.buttons["Graphic scene counter"].tap()
    XCTAssertTrue(neighbour.staticTexts["Count 1"].waitForExistence(timeout: 3))
    let runtime = neighbour.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Runtime '")).firstMatch.label
    let field = neighbour.textFields["Graphic scene draft"]
    field.tap(); field.typeText("7")
    let before = node.frame, peerFrame = neighbour.frame
    let link = app.images["1:2"]
    if connected { XCTAssertTrue(link.waitForExistence(timeout:5)) }
    let originalLinkFrame = connected ? link.frame : .zero
    let extraLink = app.images["D1"], extraFrame = dense ? extraLink.frame : .zero
    if dense {
      for index in 1...12 {
        XCTAssertTrue(app.images["N\(index)"].exists)
        XCTAssertTrue(app.images["D\(index)"].exists)
      }
    }
    let start = node.coordinate(withNormalizedOffset: .init(dx: 0.97, dy: 0.5))
    start.press(forDuration: 0.01, thenDragTo: start.withOffset(.init(dx: 38, dy: 26)),
      withVelocity: .slow, thenHoldForDuration: 0)
    XCTAssertEqual(node.frame.midX - before.midX, 38, accuracy: 6)
    XCTAssertEqual(node.frame.midY - before.midY, 26, accuracy: 6)
    XCTAssertEqual(neighbour.frame, peerFrame, "The first object contact is not camera input")
    if dense { XCTAssertNotEqual(extraLink.frame, extraFrame, "A dependency outside the old live-owner quota follows the same draft") }
    XCTAssertEqual(neighbour.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Runtime '")).firstMatch.label, runtime,
      "The live program must retain its exact runtime, not just recreate saved state")
    app.typeText("8")
    XCTAssertTrue((field.value as? String)?.contains("78") == true, "The original first responder survives object movement")
    var editedLinkLabel = "1:2"
    var curvedFrame = CGRect.zero
    if connected {
      XCTAssertNotEqual(link.frame,originalLinkFrame,"The bound line follows the moved node")
      link.doubleTap()
      let editor = app.descendants(matching:.any).matching(identifier:"graphic-label-editor").firstMatch
      XCTAssertTrue(editor.waitForExistence(timeout:3)); editor.typeText("?")
      editedLinkLabel = editor.value as? String ?? ""
      XCTAssertTrue(editedLinkLabel.contains("?"))
      workspaceWindow(in:app).coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.13)).tap()
      XCTAssertTrue(editor.waitForNonExistence(timeout:3))
      let editedLink = app.images[editedLinkLabel]
      XCTAssertTrue(editedLink.waitForExistence(timeout:3)); editedLink.tap()
      let bend = app.descendants(matching:.any).matching(identifier:"graphic-bend-handle").firstMatch
      XCTAssertTrue(bend.waitForExistence(timeout:3))
      XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"graphic-start-handle").firstMatch.exists)
      XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"graphic-end-handle").firstMatch.exists)
      let straight = editedLink.frame, initialBend = bend.frame, initialNode = node.frame
      let handle = bend.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
      handle.press(forDuration:0.01,thenDragTo:handle.withOffset(.init(dx:70,dy:0)),withVelocity:.slow,thenHoldForDuration:0)
      // Clipping follows the nodes: bending can move the whole derived bounds
      // sideways without making them much wider. Verify the held control and
      // visible link move while the node and camera do not, not a guessed width.
      XCTAssertEqual(bend.frame.midX-initialBend.midX,70,accuracy:8)
      XCTAssertGreaterThan(editedLink.frame.midX,straight.midX+40)
      XCTAssertEqual(node.frame,initialNode)
      curvedFrame = editedLink.frame
      XCTAssertEqual(neighbour.staticTexts.matching(NSPredicate(format:"label BEGINSWITH 'Runtime '")).firstMatch.label,runtime)
    }
    let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    proof.name = onPage ? "native-graphic-page-moved" : "native-graphic-board-moved"
    proof.lifetime = .keepAlways; add(proof)
    let moved = node.frame
    app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); launchPortraitFixture(app)
    XCTAssertTrue(node.waitForExistence(timeout: 10)); XCTAssertTrue(neighbour.staticTexts["Count 1"].waitForExistence(timeout: 10))
    XCTAssertEqual(node.frame.midX, moved.midX, accuracy: 6); XCTAssertEqual(node.frame.midY, moved.midY, accuracy: 6)
    if connected {
      let reopenedLink = app.images[editedLinkLabel]
      XCTAssertTrue(reopenedLink.waitForExistence(timeout:5))
      XCTAssertEqual(reopenedLink.frame.width,curvedFrame.width,accuracy:6)
      XCTAssertEqual(reopenedLink.frame.midX,curvedFrame.midX,accuracy:6)
    }
    node.doubleTap()
    let editor = app.descendants(matching: .any).matching(identifier: "graphic-label-editor").firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 3), "A completed second tap edits the native label")
    editor.typeText("?")
    let label = editor.value as? String ?? ""
    XCTAssertTrue(label.contains("?"))
    // Return remains a line break in a multiline label; leaving the object
    // commits exactly the draft that was visible in its native editor.
    workspaceWindow(in: app).coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.13)).tap()
    XCTAssertTrue(editor.waitForNonExistence(timeout: 3), "Leaving the object commits its label")
    let edited = app.images[label]
    XCTAssertTrue(edited.waitForExistence(timeout: 3))
    edited.tap()
    app.buttons["delete-agent-element"].tap()
    XCTAssertTrue(edited.waitForNonExistence(timeout: 5)); XCTAssertTrue(neighbour.staticTexts["Count 1"].exists)
    if connected { XCTAssertTrue(app.images[editedLinkLabel].waitForNonExistence(timeout:5),"Deleting a node hides its bound connection without detaching it") }
    app.terminate()
  }

  func testCompiledTypeScriptPackageFirstTapAndColdReopenOnBoardAndDocument() throws {
    continueAfterFailure = false
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "compiled-program", withExtension: "json"))
    for document in [false, true] {
      let app = XCUIApplication()
      app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-compiled-program-fixture",
        "--notebook-simulator-finger-gestures"] + (document ? ["--notebook-document-runtime-fixture"] : [])
      app.launchEnvironment["NOTEBOOK_COMPILED_PROGRAM"] = try String(contentsOf: url, encoding: .utf8)
      launchPortraitFixture(app)
      XCTAssertTrue(app.staticTexts["2² = 4"].waitForExistence(timeout: 15))
      let button = app.buttons["Увеличить x"]
      XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
      XCTAssertTrue(app.staticTexts["3² = 9"].waitForExistence(timeout: 5), "The first tap reaches the compiled module and Worker")
      let picture = XCTAttachment(screenshot: app.screenshot())
      picture.name = document ? "compiled-document-worker-result" : "compiled-board-worker-result"
      picture.lifetime = .keepAlways; add(picture)
      XCUIDevice.shared.press(.home); app.activate()
      XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["3² = 9"].exists)
      app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); launchPortraitFixture(app)
      XCTAssertTrue(app.staticTexts["3² = 9"].waitForExistence(timeout: 15), "Cold SQLite restores the package and its checkpoint, without a dev server")
      button.tap(); XCTAssertTrue(app.staticTexts["(−3)² = 9"].waitForExistence(timeout: 5))
      app.terminate()
    }
  }

  #if targetEnvironment(simulator)
  func testSelectedWaveCanFreezeForDiscussionAndResumeWhenContextIsCleared() throws {
    continueAfterFailure = false
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "wave-program", withExtension: "json"))
    for document in [false, true] {
      let app = XCUIApplication()
      app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-compiled-program-fixture", "--notebook-simulator-finger-gestures"]
        + (document ? ["--notebook-document-runtime-fixture"] : [])
      app.launchEnvironment["NOTEBOOK_COMPILED_PROGRAM_PATH"] = url.path
      launchPortraitFixture(app)
      let mode = app.switches["Проверочная мода"]
      XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
      XCTAssertTrue(app.staticTexts["Показанный результат: t = 0,650 с · c = 1,00 м/с · проверочная мода."].waitForExistence(timeout: 12))
      let field = app.images["Смещение мембраны: синий — вниз, оранжевый — вверх, светлый — ноль"]
      XCTAssertTrue(field.waitForExistence(timeout: 5)); field.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.35)).tap()
      app.buttons["notebook-context-add"].tap()
      let program = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "notebook-context-program-")).firstMatch
      XCTAssertTrue(program.waitForExistence(timeout: 3)); program.tap()
      let count = app.buttons["notebook-context-count"]
      XCTAssertTrue(count.waitForExistence(timeout: 5)); count.tap()
      let freeze = app.buttons["notebook-context-freeze-program"]
      XCTAssertTrue(freeze.waitForExistence(timeout: 3)); freeze.tap()
      let paused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !mode.isEnabled }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 8), .completed)
      let picture = XCTAttachment(screenshot: app.screenshot()); picture.name = document ? "wave-document-frozen-selection" : "wave-board-frozen-selection"
      picture.lifetime = .keepAlways; add(picture)
      count.tap(); app.buttons["notebook-context-clear"].tap()
      let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in mode.isEnabled }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 5), .completed)
      XCTAssertTrue(count.waitForNonExistence(timeout: 3)); app.terminate()
    }
  }

  func testWaveFirstControlMediaSeekAndColdReopenOnBothSurfaces() throws {
    continueAfterFailure = false
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "wave-program", withExtension: "json"))
    for document in [false, true] {
      let app = XCUIApplication()
      app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-compiled-program-fixture", "--notebook-simulator-finger-gestures"]
        + (document ? ["--notebook-document-runtime-fixture"] : [])
      app.launchEnvironment["NOTEBOOK_COMPILED_PROGRAM_PATH"] = url.path
      launchPortraitFixture(app)
      let mode = app.switches["Проверочная мода"]
      XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
      let result = app.staticTexts["Показанный результат: t = 0,650 с · c = 1,00 м/с · проверочная мода."]
      XCTAssertTrue(result.waitForExistence(timeout: 15))
      let picture = XCTAttachment(screenshot: app.screenshot()); picture.name = document ? "wave-document-mode" : "wave-board-mode"
      picture.lifetime = .keepAlways; add(picture)
      let material = app.webViews.containing(.staticText, identifier: "Волна помнит границу.").firstMatch
      let original = material.frame
      material.swipeUp()
      let modelNote = app.buttons["Модель, точность и происхождение"]
      if !modelNote.isHittable { material.swipeUp() }
      XCTAssertTrue(modelNote.isHittable, "Local scrolling exposes the complete plot and its explanation")
      XCTAssertEqual(material.frame.midX, original.midX, accuracy: 4)
      XCTAssertEqual(material.frame.midY, original.midY, accuracy: 4, "Local scrolling must not pan the board")
      let plot = XCTAttachment(screenshot: app.screenshot()); plot.name = document ? "wave-document-plot" : "wave-board-plot"
      plot.lifetime = .keepAlways; add(plot)
      material.swipeDown()
      let recording = app.switches["Запись эксперимента"]
      if !recording.isHittable { material.swipeDown() }
      recording.tap()
      let play = app.buttons["Воспроизвести запись"]
      if !play.isHittable { material.swipeUp() }
      XCTAssertTrue(play.waitForExistence(timeout: 12)); play.tap()
      let pause = app.buttons["Пауза записи"]; XCTAssertTrue(pause.waitForExistence(timeout: 5)); pause.tap()
      let seek = app.sliders["Момент записи"]
      if !seek.isHittable { material.swipeUp() }
      XCTAssertTrue(seek.waitForExistence(timeout: 5)); seek.coordinate(withNormalizedOffset: .init(dx: 0.4, dy: 0.5)).tap()
      let playhead = try XCTUnwrap(seek.value as? String)
      XCUIDevice.shared.press(.home); app.activate()
      XCTAssertTrue(play.waitForExistence(timeout: 8), "Background return must not autoplay")
      app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); launchPortraitFixture(app)
      if !seek.isHittable { app.webViews.containing(.staticText, identifier: "Волна помнит границу.").firstMatch.swipeUp() }
      XCTAssertTrue(seek.waitForExistence(timeout: 15)); XCTAssertEqual(seek.value as? String, playhead, "Cold SQLite restores the video playhead")
      XCTAssertTrue(play.exists)
      app.terminate()
    }
  }

  func testThreeDimensionalFirstOrbitSelectionPinchAndColdReopenOnBoardAndDocument() throws {
    continueAfterFailure = false
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "gears-program", withExtension: "json"))
    for document in [false, true] {
      let app = XCUIApplication()
      app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-compiled-program-fixture", "--notebook-simulator-finger-gestures"]
        + (document ? ["--notebook-document-runtime-fixture"] : [])
      app.launchEnvironment["NOTEBOOK_COMPILED_PROGRAM_PATH"] = url.path
      launchPortraitFixture(app)
      XCTAssertTrue(app.staticTexts["Вращайте · коснитесь колеса"].waitForExistence(timeout: 25))
      let material = app.webViews.containing(.button, identifier: "Общий вид").firstMatch
      let original = material.frame
      let canvas = app.images.matching(identifier: "Зубчатая передача: перетаскивание вращает вид, два пальца изменяют масштаб, касание выбирает колесо. Стрелки вращают вид.").firstMatch
      XCTAssertTrue(canvas.waitForExistence(timeout: 5)); XCTAssertTrue(canvas.isHittable)
      canvas.coordinate(withNormalizedOffset: .init(dx: 0.42, dy: 0.55)).press(forDuration: 0.05,
        thenDragTo: canvas.coordinate(withNormalizedOffset: .init(dx: 0.68, dy: 0.62)))
      XCTAssertEqual(material.frame.midX, original.midX, accuracy: 4)
      XCTAssertEqual(material.frame.midY, original.midY, accuracy: 4, "The first orbit must not drag the board")
      canvas.pinch(withScale: 1.15, velocity: 1)
      XCTAssertEqual(material.frame.width, original.width, accuracy: 4, "Model pinch must not zoom the board")
      // Semantic selection uses the same state as raycast, with an accessible alternative.
      let output = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Ведомое")).firstMatch
      if !output.isHittable { material.swipeUp() }
      XCTAssertTrue(output.waitForExistence(timeout: 5)); output.tap()
      let note = app.staticTexts["Ведомое: 24 зуба, делительный радиус 24 мм. Вращается в ту же сторону, в 2,5 раза быстрее ведущего."]
      XCTAssertTrue(note.waitForExistence(timeout: 5))
      let picture = XCTAttachment(screenshot: app.screenshot()); picture.name = document ? "gears-document-selected" : "gears-board-selected"
      picture.lifetime = .keepAlways; add(picture)
      XCUIDevice.shared.orientation = .landscapeLeft
      XCTAssertTrue(note.waitForExistence(timeout: 5)); XCUIDevice.shared.orientation = .portrait
      XCUIDevice.shared.press(.home); app.activate(); XCTAssertTrue(note.waitForExistence(timeout: 8))
      app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); launchPortraitFixture(app)
      XCTAssertTrue(note.waitForExistence(timeout: 25), "Cold SQLite retains the chosen physical part")
      app.terminate()
    }
  }

  func testTwoFourEightScientificMaterialsKeepFirstInputAcrossCameraAndColdReopen() throws {
    continueAfterFailure = false
    for count in [2, 4, 8] {
      let app = XCUIApplication()
      app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures",
        "--notebook-independent-materials=\(count)", "--notebook-scientific-materials"]
      for name in ["signal", "gears", "wave"] {
        app.launchEnvironment["NOTEBOOK_SCIENCE_" + name.uppercased()] = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name + "-program", withExtension: "json")).path
      }
      launchPortraitFixture(app)
      let impulse = app.buttons.matching(identifier: "К всплеску").firstMatch
      XCTAssertTrue(impulse.waitForExistence(timeout: 25)); XCTAssertTrue(impulse.isHittable); impulse.tap()
      XCTAssertTrue(app.staticTexts["61,337 с"].waitForExistence(timeout: 8))
      let gears = app.webViews.containing(.button, identifier: "Общий вид").firstMatch
      XCTAssertTrue(gears.waitForExistence(timeout: 25))
      gears.swipeUp()
      let output = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Ведомое")).firstMatch
      XCTAssertTrue(output.waitForExistence(timeout: 5)); output.tap()
      let note = app.staticTexts["Ведомое: 24 зуба, делительный радиус 24 мм. Вращается в ту же сторону, в 2,5 раза быстрее ведущего."].firstMatch
      XCTAssertTrue(note.waitForExistence(timeout: 5))
      let ready = XCTAttachment(screenshot: app.screenshot()); ready.name = "science-\(count)-first-controls"
      ready.lifetime = .keepAlways; add(ready)
      // The narrow empty gutter belongs to the board, not a program scroller.
      let from = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.72))
      let to = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.38))
      from.press(forDuration: 0.05, thenDragTo: to)
      let moved = XCTAttachment(screenshot: app.screenshot()); moved.name = "science-\(count)-camera"
      moved.lifetime = .keepAlways; add(moved)
      to.press(forDuration: 0.05, thenDragTo: from)
      XCUIDevice.shared.press(.home); app.activate()
      XCTAssertTrue(app.staticTexts["61,337 с"].waitForExistence(timeout: 15))
      app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); launchPortraitFixture(app)
      XCTAssertTrue(app.staticTexts["61,337 с"].waitForExistence(timeout: 25))
      XCTAssertTrue(note.waitForExistence(timeout: 25))
      app.terminate()
    }
  }

  func testDenseSignalFirstTapRotationBackgroundAndColdReopenOnBoardAndDocument() throws {
    continueAfterFailure = false
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "signal-program", withExtension: "json"))
    for document in [false, true] {
      let app = XCUIApplication()
      app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-compiled-program-fixture",
        "--notebook-simulator-finger-gestures"] + (document ? ["--notebook-document-runtime-fixture"] : [])
      app.launchEnvironment["NOTEBOOK_COMPILED_PROGRAM_PATH"] = url.path
      launchPortraitFixture(app)
      let impulse = app.buttons["К всплеску"]
      XCTAssertTrue(impulse.waitForExistence(timeout: 20)); impulse.tap()
      XCTAssertTrue(app.staticTexts["61,337 с"].waitForExistence(timeout: 8))
      let material = app.webViews.containing(.button, identifier: "К всплеску").firstMatch
      let originalFrame = material.frame
      material.swipeUp()
      let note = app.staticTexts["Синтетический затухающий сигнал с шумом и добавленным импульсом. Формула и график используют одни и те же исходные отсчёты."]
      let scrolled = XCTAttachment(screenshot: app.screenshot()); scrolled.name = document ? "signal-document-formula" : "signal-board-formula"
      scrolled.lifetime = .keepAlways; add(scrolled)
      XCTAssertTrue(note.waitForExistence(timeout: 5)); XCTAssertTrue(note.isHittable, "The formula and its explanation must be reachable inside a short fragment")
      XCTAssertEqual(material.frame.midX, originalFrame.midX, accuracy: 4)
      XCTAssertEqual(material.frame.midY, originalFrame.midY, accuracy: 4, "Reading the scene must not pan the board")
      let picture = XCTAttachment(screenshot: app.screenshot())
      picture.name = document ? "signal-document-impulse" : "signal-board-impulse"
      picture.lifetime = .keepAlways; add(picture)
      material.swipeDown()
      XCUIDevice.shared.orientation = .landscapeLeft
      XCTAssertTrue(app.staticTexts["61,337 с"].waitForExistence(timeout: 5))
      XCUIDevice.shared.orientation = .portrait
      XCUIDevice.shared.press(.home); app.activate()
      XCTAssertTrue(app.staticTexts["61,337 с"].waitForExistence(timeout: 8))
      app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); launchPortraitFixture(app)
      XCTAssertTrue(app.staticTexts["61,337 с"].waitForExistence(timeout: 20), "Cold SQLite preserves the selected raw data window")
      app.terminate()
    }
  }
  #endif

  func testLCFirstGestureParametersBackgroundAndColdReopenOnBoardAndDocument() throws {
    continueAfterFailure = false
    for document in [false, true] {
      let app = XCUIApplication()
      app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-lc-fixture",
        "--notebook-simulator-finger-gestures"] + (document ? ["--notebook-document-runtime-fixture"] : [])
      for suffix in ["html", "css", "js"] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lc", withExtension: suffix, subdirectory: "animation"))
        app.launchEnvironment["NOTEBOOK_LC_" + suffix.uppercased()] = try String(contentsOf: url, encoding: .utf8)
      }
      launchPortraitFixture(app)
      let next = app.buttons["Вперёд на четверть периода"], phase = app.sliders["Фаза"]
      XCTAssertTrue(next.waitForExistence(timeout: 10)); XCTAssertTrue(phase.exists)
      let zero = try XCTUnwrap(phase.value as? String)
      next.tap()
      let quarter = try XCTUnwrap(phase.value as? String)
      XCTAssertNotEqual(quarter, zero, "The first physical contact changes the model, not only focus")
      let proof = XCTAttachment(screenshot: app.screenshot())
      proof.name = document ? "LC-document-first-quarter" : "LC-board-first-quarter"
      proof.lifetime = .keepAlways; add(proof)
      let material = app.webViews.containing(.slider, identifier: "Фаза").firstMatch
      let originalFrame = material.frame
      let parameters = ["L", "C", "U"].map { prefix in
        app.sliders.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
      }
      var changedParameters: [String] = []
      for (parameter, position) in zip(parameters, [90.0 / 190, 15.0 / 90, 4.0 / 9]) {
        XCTAssertTrue(parameter.exists)
        let previous = parameter.value as? String
        // WebKit has no AX scrubber endpoints. Start on the actual thumb,
        // whose initial position follows the published min/max/value.
        let inset = 12 / parameter.frame.width
        parameter.coordinate(withNormalizedOffset: .init(dx: inset + position * (1 - 2 * inset), dy: 0.5))
          .press(forDuration: 0.01, thenDragTo: parameter.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.5)))
        let changed = try XCTUnwrap(parameter.value as? String)
        XCTAssertNotEqual(changed, previous); changedParameters.append(changed)
      }
      XCTAssertEqual(material.frame, originalFrame, "Parameter contacts do not move the camera or material")
      app.switches["Пуск"].tap()
      XCTAssertTrue(app.switches["Пауза"].waitForExistence(timeout: 2))
      let moving = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in phase.value as? String != quarter }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [moving], timeout: 3), .completed)
      XCUIDevice.shared.press(.home)
      app.activate()
      XCTAssertTrue(app.switches["Пуск"].waitForExistence(timeout: 5), "Background freezes the model before the OS suspends its browser")
      let frozen = try XCTUnwrap(phase.value as? String)
      XCTAssertEqual(parameters.compactMap { $0.value as? String }, changedParameters)
      app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); launchPortraitFixture(app)
      XCTAssertTrue(phase.waitForExistence(timeout: 10))
      XCTAssertEqual(phase.value as? String, frozen, "A cold process restores the final animated moment, not the previous button commit")
      XCTAssertEqual(parameters.compactMap { $0.value as? String }, changedParameters)
      let restored = XCTAttachment(screenshot: app.screenshot())
      restored.name = document ? "LC-document-cold-restored" : "LC-board-cold-restored"
      restored.lifetime = .keepAlways; add(restored)
      app.buttons["Начало"].tap(); XCTAssertEqual(phase.value as? String, zero)
      phase.coordinate(withNormalizedOffset: .init(dx: 12 / phase.frame.width, dy: 0.5)).press(forDuration: 0.01,
        thenDragTo: phase.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.5)))
      XCTAssertNotEqual(phase.value as? String, zero)
      app.buttons["Начало"].tap(); XCTAssertEqual(phase.value as? String, zero)
      app.buttons["Назад на четверть периода"].tap()
      XCTAssertNotEqual(phase.value as? String, zero)
      next.tap(); XCTAssertEqual(phase.value as? String, zero)
      app.terminate()
    }
  }

  func testIndependentMaterialsKeepFirstInputAndStateAfterColdReopening() {
    continueAfterFailure = false
    for count in [2, 4, 8] {
      let app = XCUIApplication()
      app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures",
        "--notebook-independent-materials=\(count)"]
      launchPortraitFixture(app)
      let started = ContinuousClock.now
      for number in 1...count / 2 {
        XCTAssertTrue(app.buttons["Program \(number)"].waitForExistence(timeout: 4),
          "A visible program must not wait for a passive quota or its slow neighbour")
      }
      let ready = XCTAttachment(string: "\(count) materials: native controls observed in \(started.duration(to: .now)); not touch-to-photon timing")
      ready.name = "independent-materials-\(count)-readiness"; ready.lifetime = .keepAlways; add(ready)
      let pixels = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      pixels.name = "independent-materials-\(count)-ready"; pixels.lifetime = .keepAlways; add(pixels)
      for number in 1...count / 2 {
        app.buttons["Program \(number)"].tap()
        XCTAssertTrue(app.staticTexts["Program \(number) count 1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Program \(number) count 2"].exists)
      }
      app.terminate()
      app.launchArguments.append("--notebook-reopen-fixture")
      launchPortraitFixture(app)
      for number in 1...count / 2 {
        XCTAssertTrue(app.staticTexts["Program \(number) count 1"].waitForExistence(timeout: 5),
          "A cold process must read the committed state, not a retained runtime")
      }
      app.terminate()
    }
  }

  func testHoldingLinkedImageMovesAndDeletesItsMaterialWithoutOpeningTheLink() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures",
      "--notebook-mixed-web-fixture"]
    launchPortraitFixture(app)
    let material = app.webViews.containing(.image, identifier: "Утренний свет").firstMatch
    let neighbour = app.webViews.containing(.button, identifier: "Пересчитать порции").firstMatch
    XCTAssertTrue(material.waitForExistence(timeout: 10)); XCTAssertTrue(neighbour.waitForExistence(timeout: 10))
    let before = material.frame, neighbourBefore = neighbour.frame
    let start = material.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
    start.press(forDuration: 0.45, thenDragTo: start.withOffset(.init(dx: 45, dy: 30)),
      withVelocity: .slow, thenHoldForDuration: 0)
    let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    proof.name = "linked-image-after-hold"; proof.lifetime = .keepAlways; add(proof)
    XCTAssertEqual(material.frame.midX - before.midX, 45, accuracy: 6)
    XCTAssertEqual(material.frame.midY - before.midY, 30, accuracy: 6)
    XCTAssertEqual(neighbour.frame, neighbourBefore, "Holding lifts only the material, not the camera")
    XCTAssertFalse(app.menuItems.firstMatch.exists, "The material lift cannot also open WebKit's text/link menu")
    XCTAssertFalse(app.buttons["Copy"].exists, "Native text selection cannot share the lifted link's contact")
    XCTAssertTrue(material.staticTexts["Место для спокойной работы"].exists, "The hold cannot also follow the link")
    material.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(material.staticTexts["Открыта ссылка 1"].waitForExistence(timeout: 3), "A fresh short tap still follows the native link exactly once")
    let delete = app.buttons["delete-agent-element"]
    XCTAssertTrue(delete.waitForExistence(timeout: 3))
    delete.tap()
    XCTAssertTrue(material.waitForNonExistence(timeout: 5), "Deletion removes the installed material, not just its selection")
    XCTAssertTrue(neighbour.exists); XCTAssertTrue(neighbour.staticTexts["Count 0"].exists)
    let removed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    removed.name = "linked-image-deleted-neighbour-retained"; removed.lifetime = .keepAlways; add(removed)
  }

  func testHoldingMixedProgramBackgroundMovesAndDeletesTheProgram() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures",
      "--notebook-mixed-web-fixture"]
    launchPortraitFixture(app)
    let material = app.webViews.containing(.button, identifier: "Пересчитать порции").firstMatch
    let neighbour = app.webViews.containing(.image, identifier: "Утренний свет").firstMatch
    XCTAssertTrue(material.waitForExistence(timeout: 10)); XCTAssertTrue(neighbour.waitForExistence(timeout: 10))
    let field = material.textFields["Овсянка, граммы"]
    field.tap(); field.typeText("7")
    let value = field.value as? String, before = material.frame, neighbourBefore = neighbour.frame
    let start = material.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.12))
    start.press(forDuration: 0.45, thenDragTo: start.withOffset(.init(dx: -35, dy: -25)),
      withVelocity: .slow, thenHoldForDuration: 0)
    XCTAssertEqual(material.frame.midX - before.midX, -35, accuracy: 6)
    XCTAssertEqual(material.frame.midY - before.midY, -25, accuracy: 6)
    XCTAssertEqual(neighbour.frame, neighbourBefore)
    XCTAssertEqual(field.value as? String, value); XCTAssertTrue(material.staticTexts["Count 0"].exists)
    let delete = app.buttons["delete-agent-element"]
    XCTAssertTrue(delete.waitForExistence(timeout: 3))
    let lifted = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    lifted.name = "mixed-program-lift-keeps-edited-input"; lifted.lifetime = .keepAlways; add(lifted)
    delete.tap()
    XCTAssertTrue(material.waitForNonExistence(timeout: 5)); XCTAssertTrue(neighbour.exists)
    let removed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    removed.name = "mixed-program-deleted-neighbour-retained"; removed.lifetime = .keepAlways; add(removed)
  }

  func testMixedWebControlsKeepInputWhileBackgroundPansAndPinches() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures",
      "--notebook-mixed-web-fixture"]
    launchPortraitFixture(app)
    let mood = app.webViews.containing(.image, identifier: "Утренний свет").firstMatch
    let nutrition = app.webViews.containing(.button, identifier: "Пересчитать порции").firstMatch
    XCTAssertTrue(mood.waitForExistence(timeout: 10)); XCTAssertTrue(nutrition.waitForExistence(timeout: 10))
    let before = [mood.frame, nutrition.frame]
    nutrition.buttons["Пересчитать порции"].tap()
    XCTAssertTrue(nutrition.staticTexts["Count 1"].waitForExistence(timeout: 3))
    let slider = nutrition.sliders["Размер порции"], previousValue = nutrition.sliders["Размер порции"].value as? String
    slider.coordinate(withNormalizedOffset: .init(dx: 0.25, dy: 0.5)).press(forDuration: 0.01,
      thenDragTo: slider.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.5)))
    XCTAssertNotEqual(slider.value as? String, previousValue)
    XCTAssertEqual([mood.frame, nutrition.frame], before, "Native controls must not pan the board")
    let field = nutrition.textFields["Овсянка, граммы"]
    field.tap(); field.typeText("7")
    let typed = field.value as? String
    XCTAssertTrue(typed?.contains("7") == true)
    // XCTest may use the connected hardware keyboard. Continue through the
    // application, not field.typeText (which could focus it again for us).
    let start = mood.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.15))
    start.press(forDuration: 0.01, thenDragTo: start.withOffset(.init(dx: 30, dy: 20)), withVelocity: .fast, thenHoldForDuration: 0)
    XCTAssertEqual(mood.frame.midX - before[0].midX, 30, accuracy: 6)
    XCTAssertEqual(mood.frame.midY - before[0].midY, 20, accuracy: 6)
    app.typeText("8")
    XCTAssertTrue((field.value as? String)?.contains("78") == true,
      "The existing first responder, not a second tap, receives text: \(field.value ?? "missing")")
    let focused = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    focused.name = "mixed-material-text-retained-after-pan"; focused.lifetime = .keepAlways; add(focused)
    let width = mood.frame.width
    mood.pinch(withScale: 1.2, velocity: 0.5)
    XCTAssertGreaterThan(mood.frame.width, width * 1.1)
    app.typeText("9")
    XCTAssertTrue((field.value as? String)?.contains("789") == true, "Pinch preserves the editor: \(field.value ?? "missing")")
    XCTAssertFalse(app.buttons["delete-agent-element"].exists)
    let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    proof.name = "mixed-material-controls-camera-and-keyboard"; proof.lifetime = .keepAlways; add(proof)
  }

  func testMixedWebMaterialsPanFromBackgroundAndLinkedImageWithoutActivation() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures",
      "--notebook-mixed-web-fixture"]
    launchPortraitFixture(app)
    let mood = app.webViews.containing(.image, identifier: "Утренний свет").firstMatch
    let nutrition = app.webViews.containing(.button, identifier: "Пересчитать порции").firstMatch
    XCTAssertTrue(mood.waitForExistence(timeout: 10)); XCTAssertTrue(nutrition.waitForExistence(timeout: 10))
    // Fresh outer native image frames, not child AX positions after the camera.
    for (surface, offset, delta) in [
      (mood, CGVector(dx: 0.5, dy: 0.15), CGVector(dx: 45, dy: 35)),
      (nutrition, CGVector(dx: 0.5, dy: 0.12), CGVector(dx: -35, dy: -25)),
      (mood, CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 30, dy: 20))
    ] {
      let before = [mood.frame, nutrition.frame]
      let start = surface.coordinate(withNormalizedOffset: offset)
      start.press(forDuration: 0.01, thenDragTo: start.withOffset(delta), withVelocity: .fast, thenHoldForDuration: 0)
      let after = [mood.frame, nutrition.frame]
      let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      proof.name = "mixed-material-pan-\(offset.dy)-\(delta.dx)"; proof.lifetime = .keepAlways; add(proof)
      let geometry = XCTAttachment(string: "Native material frames before: \(before)\nafter: \(after)")
      geometry.name = "mixed-material-native-geometry"; geometry.lifetime = .keepAlways; add(geometry)
      for (frame, previous) in zip(after, before) {
        XCTAssertEqual(frame.midX - previous.midX, delta.dx, accuracy: 6)
        XCTAssertEqual(frame.midY - previous.midY, delta.dy, accuracy: 6)
        XCTAssertEqual(frame.size, previous.size)
      }
      XCTAssertTrue(nutrition.staticTexts["Count 0"].exists)
      XCTAssertFalse(app.buttons["delete-agent-element"].exists)
    }
  }

  func testHoldingPassiveSVGMovesOnlyTheDrawingFromItsFirstContact() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures",
      "--notebook-passive-svg-fixture"]
    launchPortraitFixture(app)
    let svg = app.images["Пассивная схема"]
    let controls = app.webViews.containing(.button, identifier: "SVG scene counter").firstMatch
    XCTAssertTrue(svg.waitForExistence(timeout: 10)); XCTAssertTrue(controls.waitForExistence(timeout: 10))
    for delta in [CGVector(dx: 80, dy: 50), CGVector(dx: -40, dy: -30)] {
      let before = [svg.frame, controls.frame]
      let start = svg.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.45, thenDragTo: start.withOffset(delta), withVelocity: .slow, thenHoldForDuration: 0)
      let after = [svg.frame, controls.frame]
      let geometry = XCTAttachment(string: "Native material frames before: \(before)\nafter: \(after)")
      geometry.name = "passive-svg-hold-\(delta.dx)-geometry"; geometry.lifetime = .keepAlways; add(geometry)
      let pixels = XCTAttachment(screenshot: app.screenshot())
      pixels.name = "passive-svg-after-hold-\(delta.dx)"; pixels.lifetime = .keepAlways; add(pixels)
      XCTAssertTrue(app.buttons["delete-agent-element"].exists, "The first hold selects the drawing without an activating tap")
      XCTAssertEqual(after[0].midX - before[0].midX, delta.dx, accuracy: 6)
      XCTAssertEqual(after[0].midY - before[0].midY, delta.dy, accuracy: 6)
      XCTAssertEqual(after[0].size, before[0].size)
      XCTAssertEqual(after[1], before[1], "Lifting the drawing cannot move the camera or its neighbour")
      XCTAssertTrue(controls.staticTexts["Count 0"].exists)
    }
    app.buttons["delete-agent-element"].tap()
    XCTAssertTrue(svg.waitForNonExistence(timeout: 5), "Deletion must retire the actual SVG surface")
    XCTAssertTrue(controls.exists); XCTAssertTrue(controls.staticTexts["Count 0"].exists)
    let removed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    removed.name = "passive-svg-deleted-neighbour-retained"; removed.lifetime = .keepAlways; add(removed)
  }

  func testPinchingPassiveSVGScalesAfterRotationWithoutSelectingTheDrawing() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures",
      "--notebook-passive-svg-fixture"]
    launchPortraitFixture(app)
    let svg = app.images["Пассивная схема"]
    XCTAssertTrue(svg.waitForExistence(timeout: 10))
    // Gesture coordinates belong to the freshly observed native image surface,
    // never the SVG child's potentially stale accessibility rectangle.
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      var previousFrame: CGRect?
      let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        let window = app.frame, frame = svg.frame
        defer { previousFrame = frame }
        // XCTest returns before the native rotation animation finishes. Its
        // intermediate AX box can have width and height exchanged by 90°.
        return (window.width > window.height) == orientation.isLandscape
          && abs(frame.width / max(frame.height, 1) - 400.0 / 220.0) < 0.01
          && previousFrame == frame
      }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 3), .completed)
      let before = svg.frame
      svg.pinch(withScale: 1.25, velocity: 0.5)
      let after = svg.frame
      let geometry = XCTAttachment(string: "Native material frames before: \(before)\nafter: \(after)")
      geometry.name = "passive-svg-pinch-\(orientation.rawValue)-geometry"; geometry.lifetime = .keepAlways; add(geometry)
      // Capture the screen after rotation: XCTest can retain the application's
      // old portrait crop even while its native window is already landscape.
      let pixels = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      pixels.name = "passive-svg-after-pinch-\(orientation.rawValue)"; pixels.lifetime = .keepAlways; add(pixels)
      let scale = after.width / before.width
      XCTAssertGreaterThan(scale, 1.1, "A pinch beginning on SVG must reach the scene camera")
      XCTAssertEqual(after.height / before.height, scale, accuracy: 0.01)
      // The outer native image frame, not the inner SVG DOM rectangle, proves
      // scene magnification. Off-screen neighbours may legitimately retire;
      // their independent input is exercised by the pan/control regression.
      XCTAssertFalse(app.buttons["delete-agent-element"].exists, "A pair cannot also select the drawing")
      XCTAssertFalse(app.staticTexts["Обновление…"].exists,
        "Camera refinement cannot cover unchanged material with a content-update banner")
    }
  }

  func testDraggingPassiveSVGFromFirstContactMovesCameraAndKeepsControlsIndependent() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures",
      "--notebook-passive-svg-fixture"]
    launchPortraitFixture(app)
    let picture = app.images["Пассивная схема"]
    XCTAssertTrue(picture.waitForExistence(timeout: 10))
    let svg = app.images["Пассивная схема"]
    let controls = app.webViews.containing(.button, identifier: "SVG scene counter").firstMatch
    XCTAssertTrue(svg.exists); XCTAssertTrue(controls.waitForExistence(timeout: 10))
    let button = controls.buttons["SVG scene counter"]
    XCTAssertTrue(button.isHittable); button.tap()
    XCTAssertTrue(controls.staticTexts["Count 1"].waitForExistence(timeout: 3))
    let slider = controls.sliders["SVG scene slider"]
    let beforeSlider = slider.value as? String
    let beforeControl = controls.frame
    // WebKit exposes the range value but not XCTest's native scrubber bounds.
    // Drag the visible thumb before any camera movement invalidates child AX.
    slider.coordinate(withNormalizedOffset: .init(dx: 0.25, dy: 0.5)).press(forDuration: 0.01,
      thenDragTo: slider.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.5)))
    XCTAssertNotEqual(slider.value as? String, beforeSlider)
    XCTAssertEqual(controls.frame, beforeControl, "A slider gesture must not pan the camera")
    func screenshot(_ name: String) {
      let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = name; proof.lifetime = .keepAlways; add(proof)
    }
    screenshot("passive-svg-before-first-pan")
    // Use the current native image frame, not WebKit's child AX geometry after
    // movement. There is no activation tap and no corrective camera loop.
    for delta in [CGVector(dx: 90, dy: 60), CGVector(dx: -50, dy: -40)] {
      let before = [svg.frame, controls.frame]
      let start = svg.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.01, thenDragTo: start.withOffset(delta), withVelocity: .fast, thenHoldForDuration: 0)
      let after = [svg.frame, controls.frame]
      let geometry = XCTAttachment(string: "Native material frames before: \(before)\nafter: \(after)")
      geometry.name = "passive-svg-pan-\(delta.dx)-geometry"; geometry.lifetime = .keepAlways; add(geometry)
      screenshot("passive-svg-after-pan-\(delta.dx)")
      for (frame, previous) in zip(after, before) {
        XCTAssertEqual(frame.midX - previous.midX, delta.dx, accuracy: 6)
        XCTAssertEqual(frame.midY - previous.midY, delta.dy, accuracy: 6)
        XCTAssertEqual(frame.width, previous.width, accuracy: 0.01)
        XCTAssertEqual(frame.height, previous.height, accuracy: 0.01)
      }
      XCTAssertTrue(controls.staticTexts["Count 1"].exists, "Pan cannot activate a neighbour")
    }
    XCTAssertFalse(app.buttons["delete-agent-element"].exists, "Immediate movement pans rather than picking up the drawing")
  }

  func testCompanionAdditionsOwnPencilAboveTheBoard() {
    continueAfterFailure = false
    let app = XCUIApplication()
    // In this fixture direct test contacts exercise the actual spatial Pencil recognizer.
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-stacked-board-fixture", "--notebook-compact-chat-fixture"]
    launchPortraitFixture(app)
    let ink = app.otherElements["spatial-ink"]
    XCTAssertTrue(ink.waitForExistence(timeout: 8))
    let accepted = ink.value as? String
    let cover = app.descendants(matching: .any).matching(identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000004").firstMatch
    XCTAssertTrue(cover.waitForExistence(timeout: 4)); let frame = cover.frame
    app.buttons["notebook-chat-toggle"].tap(); app.buttons["notebook-companion-compose"].tap()
    app.buttons["notebook-chat-actions"].tap()
    XCTAssertTrue(app.buttons["Плагины"].waitForExistence(timeout: 3))
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "companion-additions-over-spatial-pencil"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["Плагины"].tap()
    let plugin = app.buttons["notebook-chat-resource-fixture-resource"]
    XCTAssertTrue(plugin.waitForExistence(timeout: 5), "The menu, not the paper behind it, owns this contact")
    plugin.tap()
    XCTAssertTrue(app.buttons["notebook-chat-attachment-fixture-resource"].waitForExistence(timeout: 3))
    app.buttons["notebook-chat-actions"].tap()
    XCTAssertTrue(app.buttons["Файлы и папки"].waitForExistence(timeout: 3))
    app.buttons["notebook-chat-actions"].tap()
    XCTAssertFalse(app.buttons["Файлы и папки"].exists)
    XCTAssertEqual(ink.value as? String, accepted, "Choosing a menu item must not write through to the board")
    XCTAssertEqual(cover.frame, frame)
    let start = ink.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.3))
    start.press(forDuration: 0.1, thenDragTo: start.withOffset(.init(dx: -65, dy: 30)))
    let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ink.value as? String != accepted }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 4), .completed, "Pencil resumes after the menu without resetting the scene")
    XCTAssertEqual(cover.frame, frame)
  }

  func testCompanionAdditionsDismissAndAttachWithAndWithoutKeyboard() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-compact-chat-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    app.buttons["notebook-chat-toggle"].tap()
    app.buttons["notebook-companion-compose"].tap()
    let draft = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(draft.waitForExistence(timeout: 4))
    let additions = app.buttons["notebook-chat-actions"]
    for _ in 0..<3 {
      additions.tap()
      XCTAssertTrue(app.buttons["Файлы и папки"].waitForExistence(timeout: 3))
      paper.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.3)).tap()
      XCTAssertTrue(additions.isHittable)
    }
    draft.tap(); draft.typeText("Keep draft")
    additions.tap()
    let menuProof = XCTAttachment(screenshot: app.screenshot())
    menuProof.name = "companion-additions-with-keyboard"; menuProof.lifetime = .keepAlways; add(menuProof)
    app.buttons["Плагины"].tap()
    let plugin = app.buttons["notebook-chat-resource-fixture-resource"]
    XCTAssertTrue(plugin.waitForExistence(timeout: 5)); plugin.tap()
    XCTAssertTrue(app.buttons["notebook-chat-attachment-fixture-resource"].waitForExistence(timeout: 3))
    XCTAssertEqual(draft.value as? String, "Keep draft")
    additions.tap(); app.buttons["Файлы и папки"].tap()
    let file = app.buttons["notebook-file-example.swift"]
    XCTAssertTrue(file.waitForExistence(timeout: 5)); file.tap()
    XCTAssertTrue(app.buttons["notebook-chat-attachment-example.swift"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.otherElements["notebook-code-document"].exists)
    additions.tap(); app.buttons["Проверить изменения"].tap()
    XCTAssertTrue((draft.value as? String)?.hasPrefix("Keep draft\nПроверь изменения") == true)
    let edited = draft.value as? String
    app.buttons["notebook-chat-toggle"].tap()
    app.buttons["notebook-companion-compose"].tap()
    let fullDraft = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertEqual(fullDraft.value as? String, edited)
    XCTAssertFalse(app.webViews.staticTexts["Принято поручений: 1"].exists, "Menus and attachments never send the draft")
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "companion-additions-return-to-same-draft"; proof.lifetime = .keepAlways; add(proof)
  }

  func testCompanionMessageOpensCurrentChatWithoutAHeadingOrExpandControl() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-stacked-board-fixture", "--notebook-compact-chat-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["spatial-ink"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    let text = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("Keep this draft")
    app.buttons["notebook-chat-toggle"].tap()
    let preview = app.buttons["notebook-companion-reply"]
    XCTAssertTrue(preview.waitForExistence(timeout: 8))
    XCTAssertFalse(app.staticTexts["Непрерывный разговор"].exists, "A compact message does not repeat the task heading")
    XCTAssertFalse(app.images["arrow.up.left.and.arrow.down.right"].exists)
    let close = app.buttons["notebook-companion-dismiss-reply"]
    XCTAssertEqual(preview.frame.minY, close.frame.minY, accuracy: 1, "The reply starts beside its close action, not below an empty header")
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "companion-message-without-heading"; proof.lifetime = .keepAlways; add(proof)
    preview.tap()
    let full = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Объяснение формулы, часть 1.'")).firstMatch
    XCTAssertTrue(full.waitForExistence(timeout: 5)); XCTAssertTrue(full.isHittable)
    XCTAssertEqual(text.value as? String, "Keep this draft")
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    app.buttons["notebook-chat-toggle"].tap()
    XCTAssertFalse(preview.exists, "Opening the message marks that same reply read")
  }

  func testCompanionPreviewCanBeDismissedAndOpenedWithoutLosingPaperOrDraft() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-stacked-board-fixture", "--notebook-compact-chat-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["spatial-ink"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8)); let frame = paper.frame
    let cover = app.descendants(matching: .any).matching(identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000004").firstMatch
    XCTAssertTrue(cover.waitForExistence(timeout: 4)); let coverFrame = cover.frame
    let text = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("Keep draft")
    app.buttons["notebook-chat-toggle"].tap()
    let taskCard = app.buttons["notebook-companion-task"]
    XCTAssertTrue(waitUntil { taskCard.exists || app.buttons["notebook-companion-reply"].exists }, "Work may already have completed into its reply")
    XCTAssertFalse(app.otherElements["notebook-chat-transcript"].exists)
    XCTAssertTrue(app.buttons["notebook-compact-dictation"].isHittable)
    XCTAssertTrue(app.buttons["notebook-compact-voice"].isHittable)
    let priorInk = paper.value as? String
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    // This fixture's addressed journal retains the first notebook, not its
    // unselected neighbour. Observe ink on that same owner across rotation;
    // a still-visible neighbour stroke need not stay in this bounded count.
    let inkOwner = app.descendants(matching: .any).matching(identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002").firstMatch
    let ownerFrame = inkOwner.frame
    let clearPoints = [CGPoint(x: 0.15, y: 0.4), .init(x: 0.15, y: 0.55), .init(x: 0.15, y: 0.7), .init(x: 0.15, y: 0.85)]
      .map { CGPoint(x: paper.frame.minX + paper.frame.width * $0.x, y: paper.frame.minY + paper.frame.height * $0.y) }
      .filter { point in
        let stroke = CGRect(origin: point, size: .init(width: 85, height: 40))
        return ownerFrame.contains(stroke) && !coverFrame.intersects(stroke) && !panel.frame.intersects(stroke)
      }
    XCTAssertFalse(clearPoints.isEmpty, "The companion must leave room to write")
    let start = app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: clearPoints[0].x, dy: clearPoints[0].y))
    start.press(forDuration: 0.1, thenDragTo: start.withOffset(.init(dx: 80, dy: 35)))
    let inkChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in paper.value as? String != priorInk }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [inkChanged], timeout: 4), .completed)
    let acceptedInk = paper.value as? String
    XCTAssertEqual(paper.frame, frame)
    XCTAssertLessThan(panel.frame.height, app.frame.height * 0.43)
    let first = XCTAttachment(screenshot: app.screenshot()); first.name = "companion-keeps-pencil"; first.lifetime = .keepAlways; add(first)
    let preview = app.buttons["notebook-companion-reply"]
    XCTAssertTrue(preview.waitForExistence(timeout: 8))
    XCTAssertTrue(preview.label.contains("Объяснение формулы, часть 1."))
    XCTAssertFalse(preview.label.contains("часть 16."), "Only the compact preview is shortened")
    let replyProof = XCTAttachment(screenshot: app.screenshot()); replyProof.name = "companion-long-reply-preview"; replyProof.lifetime = .keepAlways; add(replyProof)
    let controlsWithReply = app.buttons["notebook-companion-compose"].frame
    app.buttons["notebook-companion-dismiss-reply"].tap()
    XCTAssertTrue(waitUntil { !preview.exists && !taskCard.exists }, "Close removes the entire reply, not only its text")
    XCTAssertFalse(preview.exists, "Dismissal does not need a remount")
    let pencil = app.buttons["notebook-companion-compose"], origin = app.buttons["notebook-companion-compose"].frame
    XCTAssertEqual(origin.minX, controlsWithReply.minX, accuracy: 0.5)
    XCTAssertEqual(origin.minY, controlsWithReply.minY, accuracy: 0.5, "Transient cards cannot displace the control bar")
    let grip = pencil.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
    grip.press(forDuration: 0.05, thenDragTo: grip.withOffset(.init(dx: 0, dy: -90)))
    XCTAssertFalse(app.otherElements["notebook-chat-transcript"].exists, "Dragging the pencil moves the bar, never opens the chat")
    XCTAssertLessThan(pencil.frame.minY, origin.minY - 35)
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, acceptedInk)
    pencil.tap()
    let full = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Объяснение формулы, часть 1.'")).firstMatch
    XCTAssertTrue(full.waitForExistence(timeout: 5)); XCTAssertTrue(full.isHittable, "Opening unread replies reveals the exact message, not the end of its long text")
    XCTAssertEqual(text.value as? String, "Keep draft")
    app.buttons["notebook-chat-toggle"].tap()
    XCTAssertFalse(preview.exists, "The reply opened in the transcript is now read")
    XCTAssertEqual(paper.value as? String, acceptedInk); XCTAssertEqual(cover.frame, coverFrame)
    XCUIDevice.shared.orientation = .landscapeLeft
    let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
    XCUIDevice.shared.orientation = .portrait
    let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width < app.frame.height }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 5), .completed)
    XCTAssertTrue(app.buttons["notebook-companion-compose"].waitForExistence(timeout: 5))
    let rotatedProof = XCTAttachment(screenshot: app.screenshot()); rotatedProof.name = "companion-accepted-stroke-after-rotation"; rotatedProof.lifetime = .keepAlways; add(rotatedProof)
    XCTAssertEqual(paper.value as? String, acceptedInk)
    app.buttons["notebook-compact-voice"].press(forDuration: 0.8)
    XCTAssertTrue(app.staticTexts["Голосовой разговор"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["notebook-voice-wake"].exists)
    XCTAssertEqual(app.alerts.count, 0)
    app.buttons["notebook-voice-settings-close"].tap()
    XCTAssertEqual(paper.value as? String, acceptedInk)
    XCTAssertEqual(cover.frame, coverFrame)
  }

  func testComposerAddsResourcesChangesNativeSettingsAndKeepsVoiceAtNarrowWidth() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-chat-sync-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    let model = app.buttons["notebook-chat-model"]
    XCTAssertTrue(model.waitForExistence(timeout: 8)); model.tap()
    app.buttons["notebook-chat-model-picker"].tap()
    app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fixture B'")).firstMatch.tap()
    let picked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      app.buttons["notebook-chat-model-picker"].label.contains("Fixture B")
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 8), .completed)
    app.buttons["notebook-chat-effort-picker"].tap(); app.buttons["Макс."].tap()
    let effort = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      app.buttons["notebook-chat-effort-picker"].label.contains("Макс.")
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [effort], timeout: 8), .completed)
    paper.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.3)).tap()
    app.buttons["notebook-chat-context"].tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '193' AND label CONTAINS '258'")).firstMatch.waitForExistence(timeout: 3))
    paper.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.3)).tap()
    app.buttons["notebook-chat-actions"].tap(); app.buttons["Плагины"].tap()
    let resource = app.buttons["notebook-chat-resource-fixture-resource"]
    XCTAssertTrue(resource.waitForExistence(timeout: 5)); resource.tap()
    let attachment = app.buttons["notebook-chat-attachment-fixture-resource"]
    XCTAssertTrue(attachment.waitForExistence(timeout: 3))
    app.buttons["notebook-chat-actions"].tap()
    let addFiles = app.buttons["Файлы и папки"]
    XCTAssertTrue(addFiles.waitForExistence(timeout: 3)); addFiles.tap()
    let file = app.buttons["notebook-file-example.swift"]
    XCTAssertTrue(file.waitForExistence(timeout: 5)); file.tap()
    XCTAssertTrue(app.buttons["notebook-chat-attachment-example.swift"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.otherElements["notebook-code-document"].exists, "Attaching a file is not opening or moving a document")
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    let corner = panel.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: 10, dy: panel.frame.height - 10))
    corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(.init(dx: panel.frame.width - 320, dy: 80)))
    XCTAssertEqual(panel.frame.width, 320, accuracy: 4)
    for id in ["notebook-chat-dictation", "notebook-chat-voice", "notebook-chat-stop"] {
      let button = app.buttons[id]
      XCTAssertTrue(button.exists); XCTAssertTrue(button.isHittable)
      XCTAssertTrue(panel.frame.contains(button.frame)); XCTAssertEqual(button.frame.width, 44, accuracy: 1)
    }
    XCTAssertEqual(app.buttons["notebook-chat-dictation"].frame.maxX, app.buttons["notebook-chat-voice"].frame.minX, accuracy: 1)
    XCTAssertGreaterThan(model.frame.minX, app.buttons["notebook-chat-actions"].frame.maxX)
    XCTAssertLessThanOrEqual(model.frame.maxX, app.buttons["notebook-chat-dictation"].frame.minX + 1)
    XCTAssertTrue(model.isHittable); XCTAssertTrue(panel.frame.contains(model.frame))
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "composer-model-context-resource-narrow"; proof.lifetime = .keepAlways; add(proof)
  }

  func testScrollLoadsEarlierMessagesAndStopReplacesSendWithoutLosingDraftOrPaper() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-chat-sync-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    let stop = app.buttons["notebook-chat-stop"], send = app.buttons["notebook-chat-send"]
    XCTAssertTrue(stop.waitForExistence(timeout: 8)); XCTAssertFalse(send.exists)
    XCTAssertEqual(stop.frame.width, 44, accuracy: 1)
    XCTAssertTrue(app.otherElements["notebook-chat-composer"].frame.contains(stop.frame))
    XCTAssertFalse(app.buttons["История"].exists); XCTAssertFalse(app.buttons["Ранее"].exists)
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Обновить'")).firstMatch.exists)
    XCTAssertTrue(app.webViews.staticTexts["code_image.png"].waitForExistence(timeout: 5))
    let transcript = app.otherElements["notebook-chat-transcript"]
    let old = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ранний ответ 9.'")).firstMatch
    for _ in 0..<8 {
      if old.exists { break }
      transcript.swipeDown()
    }
    XCTAssertTrue(old.waitForExistence(timeout: 5), "The actual scroll gesture must request the older native page")
    let field = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    field.tap(); field.typeText("Keep this draft")
    stop.tap()
    XCTAssertTrue(send.waitForExistence(timeout: 8)); XCTAssertFalse(stop.exists)
    XCTAssertEqual(field.value as? String, "Keep this draft")
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "scroll-history-and-composer-stop"; proof.lifetime = .keepAlways; add(proof)
  }

  private func waitUntil(timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) -> Bool {
    let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
    return XCTWaiter.wait(for: [expected], timeout: timeout) == .completed
  }

  private func waitForKeyboardLayout(_ app: XCUIApplication, above control: XCUIElement) -> Bool {
    var previous = CGRect.zero, stableSince: Date?
    return waitUntil {
      let keyboard = app.keyboards.firstMatch
      guard keyboard.exists, keyboard.frame.height > 180, control.isHittable,
        control.frame.maxY <= keyboard.frame.minY + 1 else { stableSince = nil; return false }
      let frame = control.frame
      if frame != previous { previous = frame; stableSince = Date(); return false }
      if stableSince == nil { stableSince = Date() }
      return Date().timeIntervalSince(stableSince!) >= 0.6
    }
  }

  func testAddressedDictationSendsOnceFromTheCompanionWithoutOpeningOrClearingTheDraft() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-dictation-fixture", "--notebook-addressed-dictation-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    let mic = app.buttons["notebook-compact-dictation"]
    let bar = app.otherElements["notebook-companion-bar"]
    let waveform = app.otherElements["notebook-dictation-waveform"]
    XCTAssertTrue(waveform.waitForExistence(timeout: 8))
    XCTAssertEqual(bar.frame.height, 48, accuracy: 1)
    XCTAssertFalse(app.buttons["notebook-chat-toggle"].exists)
    XCTAssertFalse(app.switches["notebook-dictation-wake-toggle"].exists)
    XCTAssertTrue(bar.frame.contains(waveform.frame))
    XCTAssertTrue(app.buttons["notebook-companion-compose"].isHittable)
    let recordingProof = XCTAttachment(screenshot: app.screenshot()); recordingProof.name = "addressed-dictation-live-microphone"; recordingProof.lifetime = .keepAlways; add(recordingProof)
    let reply = app.buttons["notebook-companion-reply"]
    XCTAssertTrue(waitUntil { reply.exists && reply.label == "Принято поручений: 1" })
    XCTAssertFalse(app.otherElements["notebook-chat-transcript"].exists)
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    XCTAssertTrue(waitUntil { mic.exists && (mic.value as? String)?.contains("Ожидаю GPT") == true })
    mic.press(forDuration: 0.8)
    app.buttons["notebook-microphone-mute"].tap()
    XCTAssertTrue(waitUntil { mic.label == "Включить микрофон" })
    XCTAssertEqual(reply.label, "Принято поручений: 1")
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "addressed-dictation-single-answer"; proof.lifetime = .keepAlways; add(proof)
    XCTAssertTrue(waitUntil(timeout: 16) { !reply.exists }, "The reply expires without opening the chat")
    XCTAssertFalse(app.buttons["notebook-companion-task"].exists)
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
  }

  func testDictationInputStopsIntoAnEditableExpandedChatAndSendsExactlyOnce() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-dictation-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let paperFrame = paper.frame, ink = paper.value as? String
    app.buttons["notebook-compact-dictation"].tap()
    let input = app.otherElements["notebook-dictation-input"]
    let stop = app.buttons["notebook-dictation-review"], send = app.buttons["notebook-dictation-send"]
    XCTAssertTrue(stop.waitForExistence(timeout: 5)); XCTAssertTrue(send.isHittable)
    XCTAssertFalse(app.buttons["notebook-compact-voice"].exists)
    for control in [stop, send, app.buttons["notebook-dictation-cancel"]] {
      XCTAssertTrue(input.frame.contains(control.frame), "Controls belong inside the single recording input")
      XCTAssertGreaterThanOrEqual(control.frame.width, 44); XCTAssertGreaterThanOrEqual(control.frame.height, 44)
    }
    let recording = XCTAttachment(screenshot: app.screenshot()); recording.name = "dictation-single-input-recording"; recording.lifetime = .keepAlways; add(recording)
    stop.tap()
    let field = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 8))
    XCTAssertTrue(waitUntil { field.isEnabled && (field.value as? String) == "В Notebook работает диктовка Codex" })
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4), "Stop opens the full chat ready for editing")
    field.typeText(" edited")
    XCTAssertEqual(field.value as? String, "В Notebook работает диктовка Codex edited")
    field.tap()
    XCTAssertTrue(waitForKeyboardLayout(app, above: app.buttons["notebook-chat-send"]))
    let review = XCTAttachment(screenshot: app.screenshot()); review.name = "dictation-expanded-editable-draft"; review.lifetime = .keepAlways; add(review)
    app.buttons["notebook-chat-send"].tap()
    XCTAssertTrue(waitUntil { app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Принято поручений: 1")).firstMatch.exists })
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
    app.buttons["notebook-chat-toggle"].tap()
    app.buttons["notebook-compact-dictation"].tap()
    XCTAssertTrue(send.waitForExistence(timeout: 5)); send.tap()
    XCTAssertTrue(app.buttons["notebook-compact-dictation"].waitForExistence(timeout: 8))
    let preview = app.buttons["notebook-companion-reply"]
    XCTAssertTrue(preview.waitForExistence(timeout: 8)); XCTAssertEqual(preview.label, "Принято поручений: 2")
    XCTAssertFalse(app.otherElements["notebook-chat-transcript"].exists, "Dictation send keeps the chat collapsed and shows the answer itself")
    let reply = XCTAttachment(screenshot: app.screenshot()); reply.name = "dictation-answer-in-companion"; reply.lifetime = .keepAlways; add(reply)
    preview.tap()
    XCTAssertTrue(waitUntil { app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Принято поручений: 2")).firstMatch.exists })
    XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Принято поручений: 3")).firstMatch.exists)
    XCTAssertFalse((field.value as? String)?.contains("В Notebook") == true)
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
    let sent = XCTAttachment(screenshot: app.screenshot()); sent.name = "dictation-send-once-in-existing-chat"; sent.lifetime = .keepAlways; add(sent)
    field.tap(); field.typeText("Keep this draft")
    app.buttons["notebook-chat-dictation"].tap()
    XCTAssertTrue(stop.waitForExistence(timeout: 5)); XCTAssertTrue(send.isHittable)
    // SwiftUI merges this single child into the full composer's existing AX
    // container. Its stable owner differs from the compact recording surface.
    let fullInput = app.otherElements["notebook-chat-composer"]
    XCTAssertTrue(fullInput.frame.contains(stop.frame)); XCTAssertTrue(fullInput.frame.contains(send.frame))
    XCTAssertFalse(app.buttons["notebook-chat-voice"].exists)
    app.buttons["notebook-dictation-cancel"].tap()
    XCTAssertTrue(field.waitForExistence(timeout: 4)); XCTAssertEqual(field.value as? String, "Keep this draft")
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
  }

  func testCompactDictationControlsFitAndCancelWithoutMovingPaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-dictation-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    let mic = app.buttons["notebook-compact-dictation"]
    XCTAssertTrue(mic.isHittable); mic.tap()
    let input = app.otherElements["notebook-dictation-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    let compose = app.buttons["notebook-companion-compose"]
    XCTAssertTrue(compose.isHittable); XCTAssertFalse(compose.frame.intersects(input.frame))
    for control in [app.buttons["notebook-dictation-review"], app.buttons["notebook-dictation-send"], app.buttons["notebook-dictation-cancel"]] {
      XCTAssertTrue(control.isHittable); XCTAssertTrue(input.frame.contains(control.frame))
    }
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "compact-anchored-dictation-controls"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["notebook-dictation-cancel"].tap()
    XCTAssertTrue(mic.waitForExistence(timeout: 5))
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
  }

  func testDictationControlBesideVoiceInvokesItsOwnerWithoutLosingTheDraftOrPaper() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-chat-conversation-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    app.buttons["notebook-companion-compose"].tap()
    let dictation = app.buttons["notebook-chat-dictation"], voice = app.buttons["notebook-chat-voice"]
    XCTAssertTrue(dictation.waitForExistence(timeout: 4)); XCTAssertTrue(voice.exists)
    XCTAssertEqual(voice.label, "Начать голосовой разговор")
    XCTAssertEqual(dictation.frame.width, 44, accuracy: 1)
    XCTAssertEqual(dictation.frame.height, 44, accuracy: 1)
    XCTAssertEqual(dictation.frame.maxX, voice.frame.minX, accuracy: 1)
    XCTAssertEqual(dictation.value as? String, "Готова")
    let field = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    field.tap(); field.typeText("Keep this draft")
    field.tap()
    XCTAssertTrue(waitForKeyboardLayout(app, above: dictation))
    dictation.tap()
    let notice = app.staticTexts["notebook-dictation-notice"]
    XCTAssertTrue(notice.waitForExistence(timeout: 3))
    XCTAssertTrue(notice.label.contains("Подключите Mac"))
    let unavailableProof = XCTAttachment(screenshot: app.screenshot())
    unavailableProof.name = "dictation-owner-preserves-offline-draft"; unavailableProof.lifetime = .keepAlways; add(unavailableProof)
    XCTAssertEqual(field.value as? String, "Keep this draft")
    XCTAssertFalse(app.buttons["Завершить голосовой разговор"].exists)
    XCTAssertEqual(app.alerts.count, 0, "An offline dictation cannot open the microphone")
    app.buttons["notebook-dictation-dismiss-notice"].tap()
    voice.tap()
    let failure = app.staticTexts["notebook-chat-notice"]
    XCTAssertTrue(failure.waitForExistence(timeout: 3), "A tap must invoke the audio owner, not open another activation menu")
    XCTAssertTrue(failure.label.contains("Подключите Mac"), "This isolated fixture has no Mac and cannot open a microphone")
    voice.press(forDuration: 0.8)
    XCTAssertTrue(app.buttons["notebook-voice-wake"].exists)
    XCTAssertFalse(app.buttons["notebook-voice-method"].exists, "An unavailable mode cannot be selected and poison the next wake attempt")
    let settingsProof = XCTAttachment(screenshot: app.screenshot())
    settingsProof.name = "voice-parameters-on-hold-not-an-activation-gate"; settingsProof.lifetime = .keepAlways; add(settingsProof)
    XCTAssertEqual(app.alerts.count, 0, "Opening voice settings must not activate a microphone")
    app.buttons["notebook-voice-settings-close"].tap()
    app.buttons["notebook-chat-toggle"].tap()
    app.buttons["notebook-compact-dictation"].tap()
    XCTAssertTrue(notice.waitForExistence(timeout: 3))
    app.buttons["notebook-dictation-dismiss-notice"].tap()
    XCTAssertEqual(app.buttons["notebook-compact-voice"].label, "Начать голосовой разговор")
    app.buttons["notebook-compact-voice"].tap()
    let compactFailure = app.staticTexts["notebook-compact-voice-error"]
    XCTAssertTrue(compactFailure.waitForExistence(timeout: 3)); XCTAssertTrue(compactFailure.label.contains("Подключите Mac"))
    app.buttons["notebook-companion-compose"].tap()
    XCTAssertEqual(field.value as? String, "Keep this draft")
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "dictation-beside-voice-keeps-draft"; proof.lifetime = .keepAlways; add(proof)
  }

  func testTerminalDrawerKeepsChatTypesThroughTheKeyboardAndResizesWithoutMovingPaper() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-terminal-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let paperFrame = paper.frame, ink = paper.value as? String
    let chat = app.otherElements["notebook-chat-panel"]
    XCTAssertTrue(chat.waitForExistence(timeout: 5))
    let corner = chat.coordinate(withNormalizedOffset: .init(dx: 1, dy: 1)).withOffset(.init(dx: -5, dy: -20))
    corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(.init(dx: 0, dy: 180)))
    app.buttons["notebook-terminal-toggle"].tap()
    let terminal = app.otherElements["notebook-terminal-panel"]
    let divider = app.otherElements["notebook-terminal-divider"]
    XCTAssertTrue(terminal.waitForExistence(timeout: 5))
    XCTAssertTrue(divider.waitForExistence(timeout: 5))
    let reply = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Терминал открыт под разговором'")).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 8))
    let tree = XCTAttachment(string: app.debugDescription); tree.name = "terminal-controls-and-transcript"; tree.lifetime = .keepAlways; add(tree)
    XCTAssertTrue(reply.isHittable, "The conversation must remain visible, not just exist in an offscreen DOM")
    XCTAssertTrue(app.otherElements["notebook-chat-composer"].exists)
    XCTAssertLessThan(app.otherElements["notebook-chat-composer"].frame.maxY, terminal.frame.minY)
    let original = terminal.frame
    divider.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
      thenDragTo: divider.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).withOffset(.init(dx: 0, dy: -95)),
      withVelocity: .slow, thenHoldForDuration: 0)
    XCTAssertGreaterThan(terminal.frame.height, original.height + 35)
    let readable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in reply.isHittable }, object: nil)
    let readingRestored = XCTWaiter.wait(for: [readable], timeout: 5)
    let resized = XCTAttachment(screenshot: app.screenshot()); resized.name = "terminal-resized-keeps-readable-reply"; resized.lifetime = .keepAlways; add(resized)
    let resizedTree = XCTAttachment(string: app.debugDescription); resizedTree.name = "terminal-resized-controls"; resizedTree.lifetime = .keepAlways; add(resizedTree)
    XCTAssertEqual(readingRestored, .completed)
    XCTAssertGreaterThanOrEqual(app.otherElements["notebook-chat-transcript"].frame.height, 65)
    let resizedHeight = terminal.frame.height
    let input = app.webViews.textViews["Ввод терминала"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 8))
    input.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "An actual terminal touch must open the iPad keyboard")
    input.typeText("terminal-input-123\n")
    let echoed = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'terminal-input-123'"))
    XCTAssertTrue(echoed.firstMatch.waitForExistence(timeout: 5), "Typing must traverse the controller and remote peer before appearing in output")
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "terminal-below-chat-with-real-keyboard"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["notebook-terminal-collapse"].coordinate(withNormalizedOffset: .init(dx: 0.2, dy: 0.25)).tap()
    XCTAssertTrue(terminal.waitForNonExistence(timeout: 4))
    app.buttons["notebook-terminal-toggle"].tap()
    XCTAssertTrue(terminal.waitForExistence(timeout: 5))
    XCTAssertTrue(echoed.firstMatch.waitForExistence(timeout: 5), "Reopening must replay the same process, not a new shell")
    XCTAssertEqual(terminal.frame.height, resizedHeight, accuracy: 3)
    XCTAssertTrue(reply.isHittable, "Restoring the drawer must retain readable conversation space")
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
    let restored = XCTAttachment(screenshot: app.screenshot()); restored.name = "terminal-drawer-restored"; restored.lifetime = .keepAlways; add(restored)
    for point in [CGVector(dx: 0.85, dy: 0.2), .init(dx: 0.2, dy: 0.8), .init(dx: 0.85, dy: 0.8)] {
      let collapse = app.buttons["notebook-terminal-collapse"]
      XCTAssertGreaterThanOrEqual(collapse.frame.width, 44); XCTAssertGreaterThanOrEqual(collapse.frame.height, 44)
      collapse.coordinate(withNormalizedOffset: point).tap()
      XCTAssertTrue(terminal.waitForNonExistence(timeout: 4))
      app.buttons["notebook-terminal-toggle"].tap()
      XCTAssertTrue(terminal.waitForExistence(timeout: 5))
      XCTAssertTrue(echoed.firstMatch.waitForExistence(timeout: 5))
    }
    app.buttons["notebook-terminal-toggle"].tap()
    XCTAssertTrue(terminal.waitForNonExistence(timeout: 4))
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
  }

  func testChatBrowserSeparatesAllChatsFromExpandableProjectFolders() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-terminal-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    XCTAssertTrue(app.buttons["notebook-terminal-toggle"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["notebook-terminal-toggle"].frame.midY, app.buttons["notebook-files-toggle"].frame.midY, accuracy: 1)
    let chat = app.otherElements["notebook-chat-panel"]
    let corner = chat.coordinate(withNormalizedOffset: .init(dx: 1, dy: 1)).withOffset(.init(dx: -5, dy: -20))
    corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(.init(dx: 90, dy: 200)))
    app.buttons["notebook-chat-tasks"].tap()
    let modes = app.segmentedControls["notebook-chat-browser-mode"]
    XCTAssertTrue(modes.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["notebook-chat-project-all"].exists)
    modes.buttons["Чаты"].tap()
    let first = app.buttons["notebook-chat-task-7e7a1000-0000-4000-8000-000000000088"]
    let other = app.buttons["notebook-chat-task-7e7a1000-0000-4000-8000-000000000089"]
    XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(other.waitForExistence(timeout: 5))
    modes.buttons["Проекты"].tap()
    let folder = app.buttons["notebook-chat-project-terminal-fixture"]
    XCTAssertTrue(folder.waitForExistence(timeout: 5))
    // The selected project's folder was opened when this fixture selected it.
    if first.exists { folder.tap(); XCTAssertTrue(first.waitForNonExistence(timeout: 3)) }
    folder.tap(); XCTAssertTrue(first.waitForExistence(timeout: 5))
    app.buttons["notebook-chat-project-research-fixture"].tap()
    XCTAssertTrue(other.waitForExistence(timeout: 5))
    app.buttons["notebook-chat-project-empty-fixture"].tap()
    XCTAssertTrue(app.staticTexts["Нет чатов"].waitForExistence(timeout: 5))
    XCTAssertGreaterThan(first.frame.minX, folder.frame.minX + 20)
    XCTAssertGreaterThan(other.frame.minX, folder.frame.minX + 20)
    XCTAssertFalse(other.staticTexts["Исследование"].exists, "Folder rows do not reuse the context and layout of the all-chats projection")
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "chat-browser-project-folders"; proof.lifetime = .keepAlways; add(proof)
    modes.buttons["Чаты"].tap()
    XCTAssertTrue(first.waitForExistence(timeout: 3)); XCTAssertTrue(other.exists)
    XCTAssertFalse(folder.exists)
    other.tap()
    XCTAssertTrue(modes.waitForNonExistence(timeout: 3))
    XCTAssertTrue(app.buttons["notebook-chat-tasks"].staticTexts["Другой разговор"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.otherElements["notebook-terminal-panel"].exists, "Browsing and choosing a chat cannot start a shell")
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
  }

  func testHistoryOpensAndClosesRepeatedlyWithManySharedFragments() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-collaboration-fixture", "--notebook-history-performance-fixture"]
    launchPortraitFixture(app)
    for _ in 0..<5 {
      openSharedHistory(in: app)
      XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForExistence(timeout: 2))
      XCTAssertTrue(app.buttons["Готово"].isHittable)
      app.buttons["Готово"].tap()
      XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForNonExistence(timeout: 2))
    }
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "history-remains-dismissible-after-five-openings"; proof.lifetime = .keepAlways; add(proof)
  }

  func testSharedActionUndoKeepsTheDrawingAndHumanPlacement() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-collaboration-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout:8))
    let drawing = paper.value as? String
    XCTAssertNotNil(drawing)
    let element = app.descendants(matching:.any).matching(identifier:"agent-element-shared-element").firstMatch
    XCTAssertTrue(element.waitForExistence(timeout:8))
    app.coordinate(withNormalizedOffset:.init(dx:0.22,dy:0.18)).press(forDuration:0.45,
      thenDragTo:app.coordinate(withNormalizedOffset:.init(dx:0.45,dy:0.25)))
    XCTAssertFalse(app.staticTexts["Укажите фрагмент · протяните для области"].exists)
    openSharedHistory(in: app)
    XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForExistence(timeout: 3))
    let history = app.collectionViews["collaboration-history-list"]
    let result = app.buttons["show-action-result"].firstMatch
    // The newer human indication precedes the older action in the same history.
    // Scroll the real list to that action rather than assuming all rows are mounted.
    for _ in 0..<3 where !result.isHittable { history.swipeUp() }
    XCTAssertTrue(result.isHittable)
    result.tap()
    let showProof = XCTAttachment(screenshot: app.screenshot())
    showProof.name = "after-history-show"; showProof.lifetime = .keepAlways; add(showProof)
    XCTAssertTrue(element.waitForExistence(timeout:5))
    app.buttons["notebook-chat-toggle"].tap()
    element.tap()
    XCTAssertTrue(app.buttons["delete-agent-element"].waitForExistence(timeout:3))
    let card = app.descendants(matching: .any).matching(identifier: "notebook-context-count").firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 3), "Finger selection pins the object while the chat stays collapsed")
    for id in ["delete-agent-element", "resize-agent-element-bottomTrailing"] {
      let handle = app.descendants(matching: .any).matching(identifier: id).firstMatch
      let reachable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in handle.isHittable }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 3), .completed, "\(id): \(handle.debugDescription)")
    }
    let editingProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    editingProof.name = "finger-selection-keeps-editing-handles-reachable"
    editingProof.lifetime = .keepAlways; add(editingProof)
    let initial = element.frame
    element.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)).press(forDuration:0.3,
      thenDragTo:element.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)).withOffset(.init(dx:100,dy:60)),withVelocity:.slow,thenHoldForDuration:0)
    XCTAssertGreaterThan(element.frame.midX,initial.midX + 20)
    let moved = element.frame
    openSharedHistory(in: app)
    XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForExistence(timeout: 3))
    let continuation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ваша доработка'")).firstMatch
    for _ in 0..<3 where !continuation.isHittable { history.swipeUp() }
    XCTAssertTrue(continuation.isHittable)
    app.buttons["Отменить этот ход"].firstMatch.tap()
    app.buttons["Готово"].tap()
    XCTAssertFalse(app.staticTexts["Ход отменён"].exists, "Undo does not add a board notification")
    XCTAssertTrue(element.exists)
    XCTAssertEqual(element.frame.midX,moved.midX,accuracy:2)
    app.buttons["drawing-tool-eraser"].tap()
    XCTAssertTrue(paper.waitForExistence(timeout:3))
    XCTAssertEqual(paper.value as? String,drawing,"Рукопись принадлежит человеку при указании, показе и отмене")
  }

  func testAgentChangesStayQuietAndHistoryKeepsItsActions() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-collaboration-fixture"]
    launchPortraitFixture(app)
    let notice = app.buttons["collaboration-dismiss"]
    XCTAssertFalse(notice.exists, "Agent work is highlighted on the object, not announced in a banner")
    openSharedHistory(in: app)
    XCTAssertTrue(app.buttons["Отменить этот ход"].firstMatch.waitForExistence(timeout:3))
    XCTAssertTrue(app.buttons["show-action-result"].firstMatch.exists)
  }

  func testFingerHoldSelectsARegionWithoutSwitchingTools() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-pointer-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    XCTAssertFalse(app.buttons["drawing-tool-pointer"].exists)
    // This is a finger selection over displayed ink, not a Pencil hit-test.
    // On iOS 27 the Pencil-only leaf can be absent from the AX traversal while
    // its actual Metal pixels and native contact owner are installed.
    XCTAssertTrue(app.buttons["page-overview"].waitForExistence(timeout: 5))
    let inkReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      self.visibleInkPixelShare(in: app.screenshot(),
        normalizedRect: CGRect(x: 0.12, y: 0.16, width: 0.76, height: 0.68)) > 0.005
    }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [inkReady], timeout: 5), .completed)
    let start = app.coordinate(withNormalizedOffset:.init(dx:0.6,dy:0.25))
    let end = app.coordinate(withNormalizedOffset:.init(dx:0.85,dy:0.4))
    start.press(forDuration:0.45,thenDragTo:end)
    XCTAssertFalse(app.staticTexts["Укажите фрагмент · протяните для области"].exists)
    XCTAssertTrue(app.buttons["drawing-tool-eraser"].isHittable)
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "notebook-context-count").firstMatch.waitForExistence(timeout: 3))
    openSharedHistory(in: app)
    XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["Область"].firstMatch.exists)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "human-pointer-prepared-source"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["Готово"].tap()
    XCTAssertTrue(app.buttons["drawing-tool-eraser"].isHittable)
  }

  func testClosingQuestionRemovesVisibleIndicationAndHistoryCanResumeIt() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-pointer-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let drawing = paper.value as? String
    let baseline = app.screenshot()
    // Read the real pixels along the bottom of the dragged rectangle, away
    // from the adjacent question card and its material/shadow.
    let edge = CGRect(x: 0.28, y: 0.338, width: 0.12, height: 0.004)
    app.coordinate(withNormalizedOffset: .init(dx: 0.24, dy: 0.20))
      .press(forDuration: 0.45, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.48, dy: 0.34)))
    let card = app.descendants(matching: .any).matching(identifier: "notebook-context-count").firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    for attempt in 0..<2 {
      let indicated = app.screenshot()
      let indicatedProof = XCTAttachment(screenshot: indicated)
      indicatedProof.name = "indication-visible-\(attempt)"; indicatedProof.lifetime = .keepAlways; add(indicatedProof)
      XCTAssertGreaterThan(changedPixelShare(from: baseline, to: indicated, normalizedRect: edge), 0.04,
        "The selected frame must actually be visible before testing its removal")
      card.tap()
      app.buttons["notebook-context-clear"].tap()
      XCTAssertTrue(card.waitForNonExistence(timeout: 2))
      let closed = app.screenshot()
      let closedProof = XCTAttachment(screenshot: closed)
      closedProof.name = "indication-removed-\(attempt)"; closedProof.lifetime = .keepAlways; add(closedProof)
      XCTAssertLessThan(changedPixelShare(from: baseline, to: closed, normalizedRect: edge), 0.02,
        "Closing removes the actual selection pixels, not just the question card")
      XCTAssertEqual(paper.value as? String, drawing, "Removing indication never erases handwriting")
      if attempt == 0 {
        openSharedHistory(in: app)
        XCTAssertTrue(app.staticTexts["Область"].firstMatch.waitForExistence(timeout: 3))
        let resume = app.buttons["Продолжить этот фрагмент"]
        XCTAssertTrue(resume.waitForExistence(timeout: 2))
        resume.tap()
        app.buttons["Готово"].tap()
        // History opens from the expanded chat. Compare the same unobscured
        // paper as the baseline, not pixels covered by that unrelated window.
        app.buttons["notebook-chat-toggle"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 3))
      }
    }
  }

  func testHistoryReadsOlderContextsAndContinuesOneAddressedEntryPage() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-collaboration-fixture",
      "--notebook-history-performance-fixture", "--notebook-history-pages-fixture"]
    launchPortraitFixture(app)
    openSharedHistory(in: app)
    let nextContexts = app.buttons["context-directory-next"]
    XCTAssertTrue(nextContexts.waitForExistence(timeout: 5))
    nextContexts.tap()
    XCTAssertTrue(app.staticTexts["Фрагмент 88"].waitForExistence(timeout: 5))
    app.buttons["К новым фрагментам"].tap()
    let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "context-history-")).firstMatch
    XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
    XCTAssertTrue(app.staticTexts["Ответ 1"].waitForExistence(timeout: 5))
    let nextEntries = app.buttons["context-history-next"]
    XCTAssertTrue(nextEntries.exists); nextEntries.tap()
    XCTAssertTrue(app.staticTexts["Ответ 32"].waitForExistence(timeout: 5))
    XCTAssertFalse(nextEntries.exists, "The last bounded page does not invent another continuation")
    app.buttons["В начало"].tap()
    XCTAssertTrue(app.staticTexts["Ответ 1"].waitForExistence(timeout: 5))
    let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    proof.name = "addressed-context-history"; proof.lifetime = .keepAlways; add(proof)
  }

  func testCodexPanelLeavesNavigationAndToolsReachableInBothOrientations() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    let toggle = app.buttons["notebook-chat-toggle"]
    XCTAssertTrue(app.buttons["notebook-companion-compose"].waitForExistence(timeout: 5))
    for landscape in [false, true] {
      XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
      for expanded in [false, true] {
        if expanded { openChat(in: app) }
        let controls = ["previous-page", "page-overview", "next-page",
          "pen-controls-toggle", "drawing-tool-eraser"]
        let unobstructed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
          let window = app.frame, frame = panel.frame
          guard (window.width > window.height) == landscape,
            window.contains(frame), frame.width > (expanded ? 300 : 100),
            frame.width <= (expanded ? window.width - 36 : 352) + 1 else { return false }
          return controls.allSatisfy { id in
            let control = app.buttons[id]
            return control.exists && control.isHittable && !frame.intersects(control.frame)
          }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unobstructed], timeout: 5), .completed,
          "Chat must not cover the existing navigation or Pencil controls")
        let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        proof.name = "chat-controls-\(landscape ? "landscape" : "portrait")-\(expanded ? "expanded" : "collapsed")"
        proof.lifetime = .keepAlways; add(proof)
      }
      toggle.tap()
    }
  }

  func testCodexPanelCanCollapseFromTheWholeButtonAfterCreatingAChat() {
    assertNewChatDoesNotBlockCollapse(transcript: false)
  }

  func testCodePencilPersistsBesideNativeTextAndOwnUndoDoesNotTouchPaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-code-document-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"], frame = paper.frame, previousInk = paper.value as? String
    openChat(in: app); app.buttons["notebook-file-reopen"].tap()
    XCTAssertTrue(app.otherElements["notebook-code-document"].waitForExistence(timeout: 3))
    app.buttons["notebook-chat-toggle"].tap()
    let ink = app.otherElements["notebook-code-ink"]
    XCTAssertTrue(ink.waitForExistence(timeout: 3))
    ink.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.2)).press(forDuration: 0.1,
      thenDragTo: ink.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.3)))
    let accepted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1 действий пера"), object: ink)
    XCTAssertEqual(XCTWaiter.wait(for: [accepted], timeout: 4), .completed)
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, previousInk)
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "code-native-pencil-contact"; shot.lifetime = .keepAlways; add(shot)
    app.buttons["code-xmark"].tap()
    openChat(in: app); app.buttons["notebook-file-reopen"].tap()
    XCTAssertTrue(ink.waitForExistence(timeout: 3))
    let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1 действий пера"), object: ink)
    XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 4), .completed)
    app.buttons["code-arrow.uturn.backward"].tap()
    let undone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0 действий пера"), object: ink)
    XCTAssertEqual(XCTWaiter.wait(for: [undone], timeout: 4), .completed)
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, previousInk)
  }

  func testCodeNoteCanBeReboundThroughTheActualControlsWithoutChangingItsOriginalText() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-code-document-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"], frame = paper.frame, previousInk = paper.value as? String
    openChat(in: app); app.buttons["notebook-file-reopen"].tap()
    XCTAssertTrue(app.otherElements["notebook-code-document"].waitForExistence(timeout: 3))
    app.buttons["notebook-chat-toggle"].tap()
    let ink = app.otherElements["notebook-code-ink"]
    ink.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.2)).press(forDuration: 0.1,
      thenDragTo: ink.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.3)))
    let marker = app.buttons["Открыть исходный код с пометкой"].firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 4)); marker.tap()
    let original = app.textViews["notebook-reviewed-code-text"]
    XCTAssertTrue(original.waitForExistence(timeout: 3))
    let material = original.value as? String
    app.buttons["Перепривязать"].tap()
    XCTAssertTrue(app.buttons["code-rebind-selection"].waitForExistence(timeout: 3))
    app.buttons["code-keyboard"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
    app.textViews["notebook-code-text"].typeText("# new destination\n")
    app.buttons["code-keyboard.chevron.compact.down"].tap()
    app.buttons["code-rebind-selection"].tap()
    XCTAssertTrue(app.buttons["code-rebind-selection"].waitForNonExistence(timeout: 4))
    XCTAssertTrue(marker.waitForExistence(timeout: 4)); marker.tap()
    XCTAssertTrue(original.waitForExistence(timeout: 3))
    XCTAssertEqual(original.value as? String, material)
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "rebound-note-keeps-original-text-and-ink"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["Готово"].tap(); app.buttons["code-xmark"].tap()
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, previousInk)
  }

  func testCodeDocumentScrollsEditsAndClosesWithoutMovingPaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-code-document-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"], frame = paper.frame, ink = paper.value as? String
    openChat(in: app)
    let files = app.scrollViews["notebook-project-files"], composer = app.otherElements["notebook-chat-composer"]
    XCTAssertTrue(files.waitForExistence(timeout: 3))
    XCTAssertLessThanOrEqual(files.frame.maxY, composer.frame.minY, "The files pane ends at the full-width composer, not beside its input")
    XCTAssertGreaterThan(composer.frame.width, files.frame.width * 2)
    let panelShot = XCTAttachment(screenshot: app.screenshot()); panelShot.name = "files-right-of-conversation"; panelShot.lifetime = .keepAlways; add(panelShot)
    app.buttons["notebook-file-reopen"].tap()
    XCTAssertTrue(app.otherElements["notebook-code-document"].waitForExistence(timeout: 3))
    app.buttons["notebook-chat-toggle"].tap()
    let text = app.descendants(matching: .any).matching(identifier: "notebook-code-text").firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 3))
    let from = text.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.7))
    from.press(forDuration: 0.05, thenDragTo: text.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.3)))
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    app.buttons["code-keyboard"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
    text.typeText("# written on iPad\n")
    app.buttons["code-keyboard.chevron.compact.down"].tap()
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "code-scroll-and-native-keyboard"; shot.lifetime = .keepAlways; add(shot)
    app.buttons["code-xmark"].tap()
    XCTAssertFalse(text.exists)
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    openChat(in: app); app.buttons["notebook-file-reopen"].tap()
    XCTAssertTrue(text.waitForExistence(timeout: 3))
    XCTAssertTrue((text.value as? String)?.contains("# written on iPad") == true)
  }

  func testFilesSidebarKeepsDraftAndComposerFixedThroughKeyboardAndCollapse() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-code-document-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"], paperFrame = paper.frame, ink = paper.value as? String
    openChat(in: app)
    let files = app.scrollViews["notebook-project-files"], toggle = app.buttons["notebook-files-toggle"]
    let composer = app.otherElements["notebook-chat-composer"]
    let field = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(files.waitForExistence(timeout: 3))
    toggle.tap(); XCTAssertTrue(files.waitForNonExistence(timeout: 3))
    func checkFrame(_ expected: CGRect) {
      XCTAssertEqual(composer.frame.minX, expected.minX, accuracy: 1)
      XCTAssertEqual(composer.frame.minY, expected.minY, accuracy: 1)
      XCTAssertEqual(composer.frame.width, expected.width, accuracy: 1)
      XCTAssertEqual(composer.frame.height, expected.height, accuracy: 1)
    }
    func toggleFilesKeepingComposer() {
      let frame = composer.frame
      toggle.tap(); XCTAssertTrue(files.waitForExistence(timeout: 3)); checkFrame(frame)
      XCTAssertLessThanOrEqual(files.frame.maxY, composer.frame.minY)
      XCTAssertGreaterThan(composer.frame.width, files.frame.width * 2)
      let proof = XCTAttachment(screenshot: app.screenshot())
      proof.name = "files-above-stationary-composer"; proof.lifetime = .keepAlways; add(proof)
      toggle.tap(); XCTAssertTrue(files.waitForNonExistence(timeout: 3)); checkFrame(frame)
    }
    toggleFilesKeepingComposer()
    XCTAssertFalse(app.buttons["notebook-chat-projects"].exists, "Settings no longer take space beside the chat/project tabs")
    field.tap(); field.typeText("Keep this draft while browsing project files")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(waitForKeyboardLayout(app, above: app.buttons["notebook-chat-dictation"]))
    for _ in 0..<2 {
      toggleFilesKeepingComposer()
      XCTAssertTrue(app.keyboards.firstMatch.exists)
      XCTAssertEqual(field.value as? String, "Keep this draft while browsing project files")
    }
    let close = app.buttons["notebook-chat-toggle"]
    XCTAssertEqual(close.label, "Свернуть чат")
    close.tap(); XCTAssertTrue(close.waitForNonExistence(timeout: 3))
    openChat(in: app)
    XCTAssertEqual(field.value as? String, "Keep this draft while browsing project files")
    XCTAssertFalse(files.exists)
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
  }

  func testChatMovesResizesAndOpensSettingsWithoutMovingPaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)
    XCTAssertFalse(app.buttons["Устройства"].exists)
    XCTAssertFalse(app.buttons["Совместные ходы"].exists)
    openChat(in: app)
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    let paper = app.otherElements["paper-input"], paperFrame = paper.frame, drawing = paper.value as? String
    let before = panel.frame
    let title = app.buttons["notebook-chat-tasks"]
    let titleBefore = app.staticTexts["Новый чат"].exists
    let translation = CGVector(dx: 30 - before.minX, dy: 100 - before.minY)
    let grip = title.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
    grip.press(forDuration: 0.1, thenDragTo: grip.withOffset(translation))
    XCTAssertEqual(panel.frame.minX, 30, accuracy: 4)
    XCTAssertEqual(panel.frame.minY, 100, accuracy: 4)
    XCTAssertEqual(app.staticTexts["Новый чат"].exists, titleBefore, "Dragging the header must not also choose a conversation")
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "notebook-chat-resize").firstMatch.exists)
    for (leading, top, dx, dy) in [(false, true, -40.0, 30.0), (true, true, 30.0, 20.0), (true, false, -20.0, -30.0), (false, false, 35.0, 25.0)] {
      let moved = panel.frame
      let corner = panel.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: leading ? 10 : moved.width - 10, dy: top ? 10 : moved.height - 10))
      corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(.init(dx: dx, dy: dy)))
      let widthLimit = leading ? moved.maxX - 18 : app.frame.maxX - 18 - moved.minX
      XCTAssertEqual(panel.frame.width, min(widthLimit, max(320, moved.width + (leading ? -dx : dx))), accuracy: 4)
      XCTAssertEqual(panel.frame.height, max(240, moved.height + (top ? -dy : dy)), accuracy: 4)
      XCTAssertEqual(leading ? panel.frame.maxX : panel.frame.minX, leading ? moved.maxX : moved.minX, accuracy: 1)
      XCTAssertEqual(top ? panel.frame.maxY : panel.frame.minY, top ? moved.maxY : moved.minY, accuracy: 1)
      XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, drawing)
    }
    let resized = panel.frame
    app.buttons["notebook-chat-toggle"].tap(); openChat(in: app)
    XCTAssertEqual(panel.frame, resized)
    XCTAssertEqual(paper.frame, paperFrame)
    XCTAssertEqual(paper.value as? String, drawing)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "floating-chat-moved-and-resized"; proof.lifetime = .keepAlways; add(proof)
    openSharedHistory(in: app)
    XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForExistence(timeout: 3))
    app.buttons["Готово"].tap()
    app.buttons["notebook-chat-menu"].tap()
    XCTAssertTrue(app.buttons["Устройства"].waitForExistence(timeout: 2))
    app.buttons["Устройства"].tap()
    XCTAssertTrue(app.navigationBars["Устройства"].waitForExistence(timeout: 3))
    app.buttons["Готово"].tap()
    XCTAssertEqual(paper.frame, paperFrame)
    XCTAssertEqual(paper.value as? String, drawing)
    app.terminate()
    launchPortraitFixture(app)
    openChat(in: app)
    XCTAssertEqual(panel.frame, resized, "The scene restores the user's geometry after a cold launch")
  }

  func testCodexPanelCanCollapseAfterNewChatWithAMountedTranscript() {
    assertNewChatDoesNotBlockCollapse(transcript: true)
  }

  func testCodexPanelCanCollapseAfterNewChatWithTheKeyboard() {
    assertNewChatDoesNotBlockCollapse(transcript: true, keyboard: true)
  }

  private func assertNewChatDoesNotBlockCollapse(transcript: Bool, keyboard: Bool = false) {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    if transcript { app.launchArguments.append("--notebook-chat-conversation-fixture") }
    launchPortraitFixture(app)
    let toggle = app.buttons["notebook-chat-toggle"]
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    XCTAssertTrue(app.buttons["notebook-companion-compose"].waitForExistence(timeout: 5))
    let offsets = [CGVector(dx: 0.5, dy: 0.5), .init(dx: 0.1, dy: 0.1), .init(dx: 0.9, dy: 0.9),
      .init(dx: 0.1, dy: 0.9), .init(dx: 0.9, dy: 0.1)]
    for (index, offset) in offsets.enumerated() {
      openChat(in: app)
      if transcript && index == 0 {
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "notebook-chat-transcript")
          .firstMatch.waitForExistence(timeout: 3))
      }
      if keyboard {
        let field = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
        field.tap(); field.typeText("Keep this draft")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
      }
      let create = app.buttons["notebook-chat-new"]
      XCTAssertTrue(create.waitForExistence(timeout: 3)); create.tap()
      XCTAssertTrue(toggle.isEnabled)
      XCTAssertEqual(toggle.frame.width, 44, accuracy: 1)
      XCTAssertEqual(toggle.frame.height, 44, accuracy: 1)
      // A person taps the 44-point control, not a one-pixel SF Symbol stroke.
      toggle.coordinate(withNormalizedOffset: offset).tap()
      let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        app.buttons["notebook-companion-compose"].exists && !toggle.exists && !create.exists
          && panel.frame.width <= 352 && panel.frame.height <= 460
      }, object: nil)
      let result = XCTWaiter.wait(for: [collapsed], timeout: 3)
      let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      proof.name = "chat-collapse-after-new-\(offset.dx)-\(offset.dy)"; proof.lifetime = .keepAlways; add(proof)
      XCTAssertEqual(result, .completed, "The whole 44-point control must collapse the panel after New Chat")
    }
  }

  func testCodexPanelKeepsDraftWithoutMovingPaperOnCollapseAndRotation() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)
    let toggle = app.buttons["notebook-chat-toggle"]
    openChat(in: app)
    let field = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    XCTAssertFalse(app.keyboards.firstMatch.exists, "Opening chat does not steal Pencil focus")
    let paper = app.otherElements["paper-input"], before = app.otherElements["paper-input"].frame
    field.tap(); field.typeText("Keep this draft")
    XCTAssertEqual(paper.frame, before, "Only chat follows the keyboard safe area")
    toggle.tap(); openChat(in: app)
    XCTAssertEqual(field.value as? String, "Keep this draft")
    field.tap()
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 4), "The rotation scenario starts with actual system input, not a collapsed keyboard")
    XCUIDevice.shared.orientation = .landscapeLeft
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    var stableSince: Date?, previousWindow = CGRect.zero, previousPanel = CGRect.zero
    let inside = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard keyboard.exists else { stableSince = nil; return false }
      let window = app.frame, frame = panel.frame, keys = keyboard.frame
      guard window.width > window.height, window.insetBy(dx: -1, dy: -1).contains(frame),
        frame.width > 300, frame.height > 100, abs(keys.width - window.width) <= 1,
        keys.height > 0, window.contains(keys), keys.midY > window.midY,
        frame.maxY <= keys.minY + 1 else { stableSince = nil; return false }
      if window != previousWindow || frame != previousPanel { previousWindow = window; previousPanel = frame; stableSince = Date(); return false }
      if stableSince == nil { stableSince = Date() }
      return Date().timeIntervalSince(stableSince!) >= 0.5
    }, object: app)
    let rotation = XCTWaiter.wait(for: [inside], timeout: 5)
    let keyboardDescription = keyboard.exists ? String(describing: keyboard.frame) : "absent"
    let geometry = XCTAttachment(string: "window=\(app.frame) panel=\(panel.frame) keyboard=\(keyboardDescription)\n" + app.debugDescription)
    geometry.name = "codex-keyboard-rotation-geometry"; geometry.lifetime = .keepAlways; add(geometry)
    XCTAssertEqual(rotation, .completed)
    XCTAssertEqual(field.value as? String, "Keep this draft")
    XCTAssertTrue(field.isHittable, "The fixed composer stays reachable without scrolling the panel")
    XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY + 1)
    // The known one-line draft ends before the field's right edge. A real tap
    // in that empty first-line area sets the insertion point after its glyphs;
    // a hardware-key shortcut need not control the software keyboard selection.
    field.coordinate(withNormalizedOffset: .init(dx: 0.95, dy: 0.25)).tap()
    field.typeText(" after rotation")
    XCTAssertEqual(field.value as? String, "Keep this draft after rotation")
    XCTAssertFalse(app.buttons["notebook-chat-send"].isEnabled, "An offline fixture invents neither a task nor an executor")
    let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    proof.name = "codex-panel-keyboard-landscape"; proof.lifetime = .keepAlways; add(proof)
  }

  private func dismissDrawingSettings(_ app: XCUIApplication) {
    app.coordinate(withNormalizedOffset:.zero).withOffset(.init(dx:40,dy:40)).tap()
    XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"drawing-tool-options").firstMatch.waitForNonExistence(timeout:2))
  }

  func testPhysicalRulerMovesAndRotatesWithFingerWithoutMovingPaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"], original = paper.frame
    app.buttons["drawing-tools-more"].tap(); app.buttons["drawing-tool-ruler"].tap()
    // Preferences survive launches; establish the pose through the real UI.
    app.buttons["drawing-tool-ruler"].tap(); app.buttons["0°"].tap()
    dismissDrawingSettings(app)
    let ruler = app.descendants(matching:.any).matching(identifier:"physical-ruler").firstMatch
    XCTAssertTrue(ruler.waitForExistence(timeout:5))
    let before = ruler.frame, previous = ruler.value as? String
    let center = ruler.coordinate(withNormalizedOffset:.init(dx:0.4,dy:0.5))
    center.press(forDuration:0.05,thenDragTo:center.withOffset(.init(dx:30,dy:50)))
    XCTAssertTrue(waitUntil { (ruler.value as? String) != previous })
    XCTAssertEqual(ruler.frame.minX,before.minX+30,accuracy:4)
    XCTAssertEqual(ruler.frame.minY,before.minY+50,accuracy:4)
    let end = ruler.coordinate(withNormalizedOffset:.init(dx:0.99,dy:0.5)), moved = ruler.frame
    end.press(forDuration:0.05,thenDragTo:end.withOffset(.init(dx:-100,dy:140)))
    XCTAssertTrue(waitUntil { ruler.frame.height > moved.height+60 })
    XCTAssertEqual(paper.frame,original,"Ruler gestures must not navigate the scene")
    let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "physical-ruler-rotated"; shot.lifetime = .keepAlways; add(shot)
  }

  func testAllDrawingToolsUseRepeatedTapSettingsWithoutExtraToolbarButton() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)
    let marker = app.buttons["drawing-tool-marker"]
    XCTAssertTrue(marker.waitForExistence(timeout:5))
    marker.tap(); XCTAssertTrue(marker.isSelected); XCTAssertFalse(app.sliders["marker-width"].exists)
    app.buttons["drawing-primary-color"].tap(); app.buttons["drawing-color-green"].tap()
    marker.tap(); XCTAssertTrue(app.sliders["marker-width"].waitForExistence(timeout:2))
    app.sliders["marker-width"].adjust(toNormalizedSliderPosition:0.6)
    let chosen = app.sliders["marker-width"].value as? String
    dismissDrawingSettings(app)
    app.buttons["drawing-tool-eraser"].tap(); marker.tap(); marker.tap()
    XCTAssertTrue(app.sliders["marker-width"].waitForExistence(timeout:2))
    XCTAssertEqual(app.sliders["marker-width"].value as? String,chosen)
    XCTAssertEqual(app.buttons["drawing-primary-color"].value as? String,"Зелёная")
    dismissDrawingSettings(app)
    for (tool,setting) in [("lasso","lasso-adds-selection"),("shape","shape-width"),("text","text-size"),
      ("connector","connector-width"),("ruler","ruler-angle"),("laser","laser-duration")] {
      if tool != "lasso" {
        app.buttons["drawing-tools-more"].tap()
        let menuItem = app.buttons["drawing-tool-"+tool].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout:2)); menuItem.tap()
      } else { app.buttons["drawing-tool-lasso"].tap() }
      let button = app.buttons["drawing-tool-"+tool]
      XCTAssertTrue(button.waitForExistence(timeout:2)); XCTAssertTrue(button.isSelected)
      XCTAssertFalse(app.descendants(matching:.any).matching(identifier:setting).firstMatch.exists)
      button.tap()
      XCTAssertTrue(app.descendants(matching:.any).matching(identifier:setting).firstMatch.waitForExistence(timeout:2))
      let proof = XCTAttachment(screenshot:app.screenshot()); proof.name = "tool-settings-"+tool; proof.lifetime = .keepAlways; add(proof)
      dismissDrawingSettings(app)
      XCTAssertTrue(button.isSelected)
      XCTAssertFalse(app.buttons["pen-settings"].exists)
    }
    let proof = XCTAttachment(screenshot:app.screenshot()); proof.name = "compact-drawing-tools-toolbar"; proof.lifetime = .keepAlways; add(proof)
  }

  func testOpenToolSettingsLetOneTapSelectAnotherTool() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)
    let eraser = app.buttons["drawing-tool-eraser"], marker = app.buttons["drawing-tool-marker"]
    let pen = app.buttons["pen-controls-toggle"], color = app.buttons["drawing-primary-color"]
    XCTAssertTrue(eraser.waitForExistence(timeout:5))
    // Literal screen taps, not an accessibility activation that could bypass
    // the panel's outside-tap layer and conceal the two-tap regression.
    let markerPoint = marker.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
    let penPoint = pen.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
    eraser.tap(); eraser.tap()
    XCTAssertTrue(app.sliders["eraser-width"].waitForExistence(timeout:2))
    markerPoint.tap()
    XCTAssertTrue(marker.isSelected,"The first tap must select the real toolbar button")
    XCTAssertTrue(app.sliders["eraser-width"].waitForNonExistence(timeout:2))
    XCTAssertFalse(app.sliders["marker-width"].exists,"Switching selects, but does not open the new settings")
    marker.tap()
    XCTAssertTrue(app.sliders["marker-width"].waitForExistence(timeout:2))
    color.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)).tap()
    XCTAssertTrue(app.buttons["drawing-color-green"].waitForExistence(timeout:2))
    XCTAssertFalse(app.sliders["marker-width"].exists)
    penPoint.tap()
    XCTAssertTrue(pen.isSelected)
    XCTAssertTrue(app.buttons["drawing-color-green"].waitForNonExistence(timeout:2))
    pen.tap()
    XCTAssertTrue(app.sliders["pen-width"].waitForExistence(timeout:2))
    penPoint.tap()
    XCTAssertTrue(app.sliders["pen-width"].waitForNonExistence(timeout:2),"Repeated tap also closes the current panel")
    XCTAssertTrue(pen.isSelected)
    pen.tap()
    XCTAssertTrue(app.sliders["pen-width"].waitForExistence(timeout:2))
    app.buttons["drawing-tools-more"].coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)).tap()
    let shape = app.buttons["drawing-tool-shape"].firstMatch
    XCTAssertTrue(shape.waitForExistence(timeout:2)); shape.tap()
    XCTAssertTrue(app.buttons["drawing-tool-shape"].isSelected)
    XCTAssertFalse(app.sliders["pen-width"].exists)
    app.buttons["drawing-tool-shape"].tap()
    XCTAssertTrue(app.sliders["shape-width"].waitForExistence(timeout:2))
    eraser.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)).tap()
    XCTAssertTrue(eraser.isSelected)
    XCTAssertTrue(app.sliders["shape-width"].waitForNonExistence(timeout:2))
    let proof = XCTAttachment(screenshot:app.screenshot())
    proof.name = "one-tap-tool-switch-through-open-settings"; proof.lifetime = .keepAlways; add(proof)
  }

  func testToolSettingsOpenOnRepeatedTapAndPreserveSelection() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)

    let pen = app.buttons["pen-controls-toggle"]
    let eraser = app.buttons["drawing-tool-eraser"]
    XCTAssertTrue(pen.waitForExistence(timeout: 5))
    XCTAssertTrue(
      eraser.waitForExistence(timeout: 2),
      "Ластик должен быть доступен рядом с ручкой без раскрытия настроек"
    )
    XCTAssertEqual(pen.frame.width, pen.frame.height, accuracy: 1)
    XCTAssertEqual(eraser.frame.width, eraser.frame.height, accuracy: 1)
    XCTAssertEqual(pen.frame.width, eraser.frame.width, accuracy: 1)
    XCTAssertFalse(pen.frame.intersects(eraser.frame))
    XCTAssertEqual(pen.frame.midY, eraser.frame.midY, accuracy: 1)
    XCTAssertLessThanOrEqual(
      abs(eraser.frame.minX - app.buttons["drawing-tool-marker"].frame.maxX),
      10,
      "Ластик стоит рядом с маркером в компактном ряду инструментов"
    )

    let settings = app.sliders["pen-width"]
    let eraserSettings = app.sliders["eraser-width"]
    XCTAssertFalse(app.buttons["pen-settings"].exists, "Настройки не занимают отдельное место на панели")
    XCTAssertFalse(settings.exists)
    eraser.tap()
    XCTAssertTrue(eraser.isSelected)
    XCTAssertFalse(eraserSettings.exists, "Первое нажатие только выбирает ластик")
    eraser.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.1)).tap()
    XCTAssertTrue(eraserSettings.waitForExistence(timeout: 2))
    XCTAssertFalse(settings.exists, "У ластика открываются только его настройки")
    XCTAssertFalse(app.staticTexts["Ластик"].exists,"No redundant title in the compact panel")
    XCTAssertFalse(app.buttons["Закрыть настройки"].exists)
    app.buttons["eraser-size-16"].tap()
    XCTAssertEqual(eraserSettings.value as? String,"16 пунктов")
    eraserSettings.adjust(toNormalizedSliderPosition: 0.1)
    let initialEraserWidth = eraserSettings.value as? String
    eraserSettings.adjust(toNormalizedSliderPosition: 0.7)
    let chosenEraserWidth = eraserSettings.value as? String
    XCTAssertNotEqual(chosenEraserWidth, initialEraserWidth)
    let eraserProof = XCTAttachment(screenshot: app.screenshot())
    eraserProof.name = "eraser-settings-from-repeated-tap"; eraserProof.lifetime = .keepAlways; add(eraserProof)
    dismissDrawingSettings(app)
    XCTAssertTrue(eraserSettings.waitForNonExistence(timeout: 2))
    XCTAssertTrue(eraser.isSelected)
    eraser.tap()
    XCTAssertTrue(eraserSettings.waitForExistence(timeout: 2))
    XCTAssertEqual(eraserSettings.value as? String, chosenEraserWidth)
    dismissDrawingSettings(app)
    XCTAssertTrue(eraserSettings.waitForNonExistence(timeout: 2))
    let inactivePen = pen.screenshot()
    pen.tap()
    XCTAssertFalse(settings.exists, "Первое касание выбирает ручку и сохраняет компактную панель")
    XCTAssertTrue(pen.isSelected)
    XCTAssertFalse(eraser.isSelected)
    let selectedPen = pen.screenshot()
    // Sample the selection background beside the icon, so the pen's ink colour
    // alone cannot satisfy the visible-selection contract.
    let selectionBackground = CGRect(x: 0.2, y: 0.4, width: 0.08, height: 0.2)
    XCTAssertGreaterThan(
      changedPixelShare(from: inactivePen, to: selectedPen, normalizedRect: selectionBackground),
      0.8,
      "Выбранная ручка должна показывать заметную подложку, как ластик"
    )
    let penProof = XCTAttachment(screenshot: app.screenshot())
    penProof.name = "selected-pen-highlight"
    penProof.lifetime = .keepAlways
    add(penProof)

    pen.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.1)).tap()
    XCTAssertTrue(settings.waitForExistence(timeout: 2), "Повторное нажатие всей областью инструмента открывает настройки")
    XCTAssertFalse(eraserSettings.exists)
    XCTAssertTrue(app.sliders["pen-minimum-opacity"].exists)
    XCTAssertFalse(app.buttons["pen-color-red"].exists,"The primary palette belongs only to the toolbar")
    dismissDrawingSettings(app)
    app.buttons["drawing-primary-color"].tap(); app.buttons["drawing-color-red"].tap()
    XCTAssertEqual(app.buttons["drawing-primary-color"].value as? String,"Красная")
    pen.tap()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pen-stroke-preview").firstMatch.waitForExistence(timeout: 2))
    let previewProof = XCTAttachment(screenshot: app.screenshot())
    previewProof.name = "actual-pen-pressure-preview"; previewProof.lifetime = .keepAlways; add(previewProof)
    dismissDrawingSettings(app)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 2))
    XCTAssertTrue(pen.isSelected, "Закрытие настроек сохраняет выбранную ручку")

    XCTAssertFalse(app.buttons["drawing-tool-pointer"].exists)
    XCTAssertTrue(pen.isSelected, "Selection by finger does not add a drawing mode")

    pen.tap()
    XCTAssertTrue(settings.waitForExistence(timeout: 2))
    XCTAssertEqual(app.buttons["drawing-primary-color"].value as? String,"Красная", "Повторное открытие сохраняет параметры ручки")
    app.otherElements["paper-input"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.6)).tap()
    XCTAssertTrue(settings.waitForNonExistence(timeout: 2), "Нажатие вне настроек закрывает их")
    XCTAssertTrue(pen.isSelected, "Настройки не создают скрытого инструмента редактирования")
  }

  func testEveryArtifactCornerResizesWithoutMovingTheOppositeCornerOrPaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-collaboration-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let drawing = paper.value as? String, paperFrame = paper.frame
    let element = app.descendants(matching: .any).matching(identifier: "agent-element-shared-element").firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 8))
    let toggle = app.buttons["notebook-chat-toggle"]
    if toggle.exists { toggle.tap() }
    element.tap()
    XCTAssertTrue(app.buttons["delete-agent-element"].waitForExistence(timeout: 4))
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "resize-agent-element").firstMatch.exists)
    for (name, leading, top) in [("topLeading", true, true), ("topTrailing", false, true), ("bottomLeading", true, false), ("bottomTrailing", false, false)] {
      let corner = app.descendants(matching: .any).matching(identifier: "resize-agent-element-" + name).firstMatch
      XCTAssertTrue(corner.waitForExistence(timeout: 4)); XCTAssertTrue(corner.isHittable)
      let before = element.frame
      // The upper-left center overlaps the collapsed chat. Use the visible
      // interior of each 44-point target, not that unrelated control.
      let start = corner.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.75))
      start.press(forDuration: 0.05, thenDragTo: start.withOffset(.init(dx: leading ? -22 : 22, dy: top ? -18 : 18)), withVelocity: .slow, thenHoldForDuration: 0)
      let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.frame.width > before.width + 10 && element.frame.height > before.height + 8 }, object: nil)
      let outcome = XCTWaiter.wait(for: [resized], timeout: 4)
      if outcome != .completed {
        let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "corner-resize-failure"; proof.lifetime = .keepAlways; add(proof)
      }
      XCTAssertEqual(outcome, .completed, "Corner \(name): \(before) -> \(element.frame), target \(corner.frame)")
      XCTAssertEqual(leading ? element.frame.maxX : element.frame.minX, leading ? before.maxX : before.minX, accuracy: 2)
      XCTAssertEqual(top ? element.frame.maxY : element.frame.minY, top ? before.maxY : before.minY, accuracy: 2)
      XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, drawing)
      XCTAssertEqual(app.buttons.matching(identifier: "delete-agent-element").count, 1)
    }
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "four-corners-one-frame"; proof.lifetime = .keepAlways; add(proof)
  }

  func testSuccessiveArtifactChoicesLeaveOneFrameAndClearTogether() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-agent-element-fixture",
      "--notebook-selection-transition-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let first = app.otherElements["agent-element-shared-element"]
    let second = app.otherElements["agent-element-second-element"]
    XCTAssertTrue(first.waitForExistence(timeout: 8)); XCTAssertTrue(second.waitForExistence(timeout: 8))
    let paper = app.otherElements["paper-input"], paperFrame = paper.frame, ink = paper.value as? String
    let baseline = app.screenshot()
    let frame = first.frame, screen = app.frame
    let edge = CGRect(x: (frame.minX + frame.width * 0.2) / screen.width,
      y: (frame.minY - 2) / screen.height, width: frame.width * 0.5 / screen.width, height: 4 / screen.height)
    first.tap()
    XCTAssertEqual(app.buttons.matching(identifier: "delete-agent-element").count, 1)
    let selected = app.screenshot()
    XCTAssertGreaterThan(changedPixelShare(from: baseline, to: selected, normalizedRect: edge), 0.03)
    second.tap()
    XCTAssertEqual(app.buttons.matching(identifier: "delete-agent-element").count, 1)
    XCTAssertGreaterThan(app.buttons["delete-agent-element"].frame.midY, second.frame.minY - 65)
    let replaced = app.screenshot()
    XCTAssertLessThan(changedPixelShare(from: baseline, to: replaced, normalizedRect: edge), 0.02,
      "The previous artifact cannot retain a context outline after the next choice")
    let count = app.buttons["notebook-context-count"]
    XCTAssertTrue(count.waitForExistence(timeout: 3)); XCTAssertEqual(count.value as? String, "1")
    count.tap(); app.buttons["notebook-context-clear"].tap()
    XCTAssertTrue(count.waitForNonExistence(timeout: 3))
    XCTAssertEqual(app.buttons.matching(identifier: "delete-agent-element").count, 0,
      "Clearing context also clears editing, not just the counter")
    first.tap()
    XCTAssertTrue(count.waitForExistence(timeout: 3))
    paper.coordinate(withNormalizedOffset: .init(dx: 0.86, dy: 0.16)).tap()
    XCTAssertTrue(count.waitForNonExistence(timeout: 3))
    XCTAssertEqual(app.buttons.matching(identifier: "delete-agent-element").count, 0)
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: replaced)
    proof.name = "only-second-artifact-selected"; proof.lifetime = .keepAlways; add(proof)
  }

  func testPersonMovesAndDeletesAnAgentElement() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-agent-element-fixture",
      "--notebook-simulator-finger-gestures",
    ]
    launchPortraitFixture(app)

    let sharedElement = app.otherElements["agent-element-shared-element"]
    XCTAssertTrue(sharedElement.waitForExistence(timeout: 8))
    let initialFrame = sharedElement.frame
    let paper = app.otherElements["paper-input"]
    let paperFrame = paper.frame, drawing = paper.value as? String

    sharedElement.tap()
    let delete = app.buttons["delete-agent-element"]
    XCTAssertTrue(
      delete.waitForExistence(timeout: 3),
      "Выбранный общий элемент должен показать действие удаления"
    )
    XCTAssertFalse(app.descendants(matching: .any)["move-agent-element"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["agent-question-card"].exists)
    let count = app.buttons["notebook-context-count"]
    XCTAssertTrue(count.waitForExistence(timeout: 3))
    XCTAssertEqual(count.value as? String, "1")
    XCTAssertLessThan(count.frame.width, 45)

    var expectedFrame = initialFrame
    for delta in [CGVector(dx: 100, dy: 60), CGVector(dx: -60, dy: 40)] {
      let start = sharedElement.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.3, thenDragTo: start.withOffset(delta),
        withVelocity: .slow, thenHoldForDuration: 0)
      expectedFrame = expectedFrame.offsetBy(dx: delta.dx, dy: delta.dy)
      XCTAssertEqual(sharedElement.frame.minX, expectedFrame.minX, accuracy: 3,
        "Следующий жест начинается с принятого положения, без возврата к прежнему")
      XCTAssertEqual(sharedElement.frame.minY, expectedFrame.minY, accuracy: 3)
      XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, drawing)
    }

    XCTAssertEqual(paper.frame, paperFrame)
    XCTAssertEqual(paper.value as? String, drawing)
    XCTAssertEqual(count.value as? String, "1", "Moving keeps the original pinned source")
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "body-hold-moved-artifact-with-compact-context-count"; proof.lifetime = .keepAlways; add(proof)
    openChat(in: app)
    XCTAssertTrue(count.waitForExistence(timeout: 3)); XCTAssertEqual(count.value as? String, "1")
    XCTAssertFalse(app.staticTexts["Амир указал область"].exists)
    app.buttons["notebook-chat-toggle"].tap()
    XCTAssertEqual(paper.frame, paperFrame)

    app.buttons["delete-agent-element"].tap()
    XCTAssertFalse(
      sharedElement.waitForExistence(timeout: 2),
      "Удаление должно убрать общий элемент с листа"
    )
  }

  func testDocumentTextOpensMarkdownEditorOnDoubleTap() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture"]
    launchPortraitFixture(app)
    let sourceRegion = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Исходник: # Живая математика")).firstMatch
    XCTAssertTrue(sourceRegion.waitForExistence(timeout: 20), app.debugDescription)
    sourceRegion.doubleTap()
    let editor = app.textViews["document-source-editor"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
    XCTAssertTrue((editor.value as? String)?.contains("Живая математика") == true)
    editor.tap(); editor.typeText("\n\nНовая строка\n\n")
    XCTAssertTrue(app.staticTexts["Сохранено"].waitForExistence(timeout: 15))
    app.buttons["Лист"].tap()
    XCTAssertFalse(editor.exists)
    app.buttons["Код"].tap()
    XCTAssertTrue((editor.value as? String)?.contains("Новая строка") == true)
    let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Native source after paper double tap"
    image.lifetime = .keepAlways; add(image)
  }

  func testDocumentRuntimeRendersMarkdownLatexAndInteractiveContent() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(350))
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture",
    ]
    launchPortraitFixture(app)

    let runtime = app.descendants(matching: .any)
      .matching(identifier: "document-runtime")
      .firstMatch
    XCTAssertTrue(
      runtime.waitForExistence(timeout: 8),
      "Открытый документ должен создать один живой WebKit runtime"
    )
    try await Task.sleep(for: .seconds(2))
    XCTAssertEqual(
      app.state,
      .runningForeground,
      "Markdown, LaTeX и интерактивный блок должны жить без падения приложения"
    )

    let slider = app.webViews.sliders.firstMatch
    XCTAssertTrue(slider.waitForExistence(timeout: 5)); XCTAssertTrue(slider.isHittable)
    let before = try XCTUnwrap(slider.value as? String)
    // The fixture starts at x=3 on [0,10]. Touch the actual thumb directly;
    // there is no separate activation tap or replay into a later runtime.
    slider.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.5)).press(forDuration: 0.05,
      thenDragTo: slider.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.5)),
      withVelocity: .slow, thenHoldForDuration: 0)
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (slider.value as? String).map { $0 != before } == true
    }, object: nil)], timeout: 3)
    XCTAssertTrue(slider.isHittable, "Accepted state cannot revoke the same control's native input")

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "document-markdown-latex-interactive"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testDocumentContentFlowsAcrossFiniteA4Pages() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(350))
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture",
    ]
    launchPortraitFixture(app)

    let firstPage = app.otherElements.matching(
      NSPredicate(format: "label BEGINSWITH 'Страница 1 из '")
    ).firstMatch
    XCTAssertTrue(
      firstPage.waitForExistence(timeout: 8),
      "WebKit должен разбить содержание на конечные листы"
    )
    let surface = app.otherElements["page-turn-surface"]
    let firstFrame = firstPage.frame
    let firstCount = firstPage.label.components(separatedBy: " из ").last
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"), object: surface
    )], timeout: 8)
    XCTAssertEqual(
      firstFrame.height / firstFrame.width,
      841.88976378 / 595.275590551,
      accuracy: 0.03,
      "Экранный лист должен сохранять физическую пропорцию A4"
    )
    // Each UIKit sheet now receives one prepared physical DOM fragment, not
    // the entire offscreen document. The next sheet must be checked after a
    // real page curl, rather than requiring deleted offscreen paper nodes.
    surface.swipeLeft()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"), object: surface
    )], timeout: 3)
    let secondSheet = app.otherElements["page-turn-page-1"]
    let secondPage = secondSheet.otherElements.matching(
      NSPredicate(format: "label BEGINSWITH 'Страница 2 из '")
    ).firstMatch
    XCTAssertTrue(
      secondPage.waitForExistence(timeout: 3),
      "Длинный текст должен перейти на второй лист"
    )
    let centered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      secondPage.exists && abs(secondPage.frame.midX - firstFrame.midX) <= 4
    }, object: nil)
    await fulfillment(of: [centered], timeout: 3)
    XCTAssertEqual(secondPage.label.components(separatedBy: " из ").last, firstCount)
    XCTAssertEqual(secondPage.frame.width, firstFrame.width, accuracy: 1)
    XCTAssertEqual(secondPage.frame.height, firstFrame.height, accuracy: 1)
    XCTAssertEqual(
      secondPage.frame.height / secondPage.frame.width,
      841.88976378 / 595.275590551,
      accuracy: 0.03,
      "Продолжение остаётся отдельным листом A4, не вертикальной лентой"
    )
    // Accessibility appends its localized role (for example ", область") to
    // the paper label; the page address remains its prefix, not the whole label.
    let pageLabels = secondSheet.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Страница '"))
      .allElementsBoundByIndex.map(\.label)
    let addresses = XCTAttachment(string: pageLabels.joined(separator: "\n"))
    addresses.name = "finite-A4-native-accessibility-page-addresses"; addresses.lifetime = .keepAlways; add(addresses)
    XCTAssertEqual(Set(pageLabels), [secondPage.label],
      "Физическая оболочка не содержит копий чужих листов")
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "finite-A4-page-after-native-curl"; proof.lifetime = .keepAlways; add(proof)
  }

  func testStoredDocumentPageBecomesTheVisiblePhysicalSheet() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(350))
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture",
      "--notebook-document-page-three-fixture",
    ]
    launchPortraitFixture(app)

    let selectedSheet = app.otherElements["page-turn-page-2"]
    let thirdPage = selectedSheet.otherElements.matching(
      NSPredicate(format: "label BEGINSWITH 'Страница 3 из '")
    ).firstMatch
    XCTAssertTrue(thirdPage.waitForExistence(timeout: 8))
    // WebKit publishes the document tree before its fixed page is positioned.
    // The selected sheet's completed placement owns this assertion.
    let centered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        thirdPage.exists && abs(thirdPage.frame.midX - app.frame.midX) <= 4
      },
      object: nil
    )
    await fulfillment(of: [centered], timeout: 8)
    XCTAssertEqual(
      thirdPage.frame.midX,
      app.frame.midX,
      accuracy: 4,
      "SessionPresence должен поставить выбранный физический лист в центр"
    )

    let storedText = try visibleDocumentText(app: app, surface: app.otherElements["page-turn-surface"], name: "stored-document-page-3")
    // A marker in the old complete accessibility DOM could exist on an
    // unshown column. Compare actual visible text with an independent landing
    // through two native turns, without baking a typesetting boundary into IDs.
    app.terminate()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture"]
    launchPortraitFixture(app)
    let surface = app.otherElements["page-turn-surface"]
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"), object: surface
    )], timeout: 8)
    for page in 2...3 {
      // Unlike an early swipe into an unprepared neighbour, the page control
      // retains an explicit destination until UIKit can install that sheet.
      app.buttons["next-page"].tap()
      await fulfillment(of: [XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value BEGINSWITH %@", "Страница \(page) из "), object: surface
      )], timeout: 3)
      let paper = app.otherElements["page-turn-page-\(page - 1)"].otherElements.matching(
        NSPredicate(format: "label BEGINSWITH %@", "Страница \(page) из ")
      ).firstMatch
      XCTAssertTrue(paper.waitForExistence(timeout: 3))
      await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        paper.exists && abs(paper.frame.midX - app.frame.midX) <= 4
      }, object: nil)], timeout: 3)
    }
    let turnedText = try visibleDocumentText(app: app, surface: surface, name: "turned-document-page-3-reference")
    let sections = try NSRegularExpression(pattern: #"Раздел\s+(\d+)"#)
    func sectionIDs(_ text: String) -> [String] {
      sections.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range(at: 1), in: text)!])
      }
    }
    XCTAssertGreaterThanOrEqual(sectionIDs(storedText).count, 4)
    XCTAssertEqual(sectionIDs(storedText), sectionIDs(turnedText),
      "Сохранённый выбор должен показывать тот же физический лист, что и два настоящих перелистывания")
  }

  func testStoredNotebookContentSurvivesForwardAndReverseTurns() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-page-turn-content-fixture",
      "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let surface = app.otherElements["page-turn-surface"]
    let paper = app.otherElements["paper-input"].firstMatch
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let originalFrame = paper.frame, originalInk = paper.value as? String
    XCTAssertGreaterThan(originalFrame.width, app.frame.width * 0.9)
    func assertVisiblePage(_ page: Int, name: String) {
      let marker = app.otherElements["agent-element-page-marker-\(page - 1)"]
      XCTAssertTrue(marker.waitForExistence(timeout: 5), "The native landing must expose the destination")
      let frame = marker.frame, screen = app.frame, screenshot = app.screenshot()
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
      let rgb = [0xeaabab, 0xacd6b8, 0xaebfea, 0xedcd92, 0xceafdc, 0x9bd5de][page - 1]
      let expected = (rgb >> 16, (rgb >> 8) & 255, rgb & 255)
      let share = pixelShare(in: screenshot, normalizedRect: .init(
        x: (frame.minX + 20 - screen.minX) / screen.width,
        y: (frame.minY + 20 - screen.minY) / screen.height,
        width: 40 / screen.width, height: 20 / screen.height)) { r, g, b, a in
          a > 240 && abs(Int(r) - expected.0) < 15
            && abs(Int(g) - expected.1) < 15 && abs(Int(b) - expected.2) < 15
        }
      XCTAssertGreaterThan(share, 0.9, "The visible destination's own color, not its model counter, identifies page \(page)")
    }
    for usesButtons in [true, false] {
      var previous = 1
      for page in Array(2...6) + Array((1...5).reversed()) {
        let forward = page > previous
        if usesButtons { app.buttons[forward ? "next-page" : "previous-page"].tap() }
        else if forward { surface.swipeLeft() } else { surface.swipeRight() }
        await fulfillment(of: [XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value BEGINSWITH %@", "Страница \(page) из "), object: surface
        )], timeout: 5)
        assertVisiblePage(page, name: "stored-paper-\(usesButtons ? "button" : "swipe")-\(previous)-to-\(page)")
        XCTAssertTrue(paper.waitForExistence(timeout: 5), "The landed sheet must accept input")
        XCTAssertEqual(paper.frame, originalFrame)
        XCTAssertEqual(paper.value as? String, originalInk)
        previous = page
      }
      XCUIDevice.shared.press(.home)
      app.activate()
      XCTAssertTrue(paper.waitForExistence(timeout: 8))
      XCTAssertEqual(paper.frame, originalFrame)
      assertVisiblePage(1, name: "stored-paper-resume-\(usesButtons)")
    }
  }

  func testNotebookPageTurnCommitsBothDirections() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)

    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    let paper = app.otherElements["paper-input"].firstMatch
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let inkBefore = paper.value as? String
    surface.swipeLeft()

    let landed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"),
      object: surface
    )
    wait(for: [landed], timeout: 3)

    surface.swipeRight()
    let returned = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из '"),
      object: surface
    )
    wait(for: [returned], timeout: 3)
    XCTAssertEqual(paper.value as? String, inkBefore, "Finger navigation must not become an emulated Pencil stroke")
    XCTAssertEqual(app.state, .runningForeground)
  }

  func testNotebookPageGeometrySurvivesRepeatedForwardAndReverseTurns() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    let paper = app.otherElements["paper-input"].firstMatch
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let originalSurface = surface.frame, originalPaper = paper.frame
    let originalInk = paper.value as? String
    XCTAssertGreaterThan(originalSurface.height, originalSurface.width)
    for turn in 0..<20 {
      let forward = turn.isMultiple(of: 2), page = forward ? 2 : 1
      if forward { surface.swipeLeft() } else { surface.swipeRight() }
      wait(for: [XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value BEGINSWITH %@", "Страница \(page) из "), object: surface
      )], timeout: 5)
      XCTAssertTrue(paper.waitForExistence(timeout: 5))
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = "page-geometry-turn-\(turn + 1)"; attachment.lifetime = .keepAlways; add(attachment)
      XCTAssertEqual(surface.frame.width, originalSurface.width, accuracy: 1)
      XCTAssertEqual(surface.frame.height, originalSurface.height, accuracy: 1)
      XCTAssertEqual(paper.frame, originalPaper, "The real Pencil surface must keep its physical paper rectangle after turn \(turn + 1)")
      if !forward { XCTAssertEqual(paper.value as? String, originalInk) }
    }
  }

  func testNotebookPaperKeepsItsBoundsAfterRotatingAndTurningBack() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let surface = app.otherElements["page-turn-surface"]
    let paper = app.otherElements["paper-input"].firstMatch
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let originalPaper = paper.frame
    for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
      XCUIDevice.shared.orientation = orientation
      wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        (app.frame.width > app.frame.height) == orientation.isLandscape
      }, object: nil)], timeout: 5)
      for page in [2, 1] {
        if page == 2 { surface.swipeLeft() } else { surface.swipeRight() }
        wait(for: [XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value BEGINSWITH %@", "Страница \(page) из "), object: surface
        )], timeout: 5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "paper-rotated-\(orientation.rawValue)-page-\(page)"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(paper.frame.width / paper.frame.height, 834.0 / 1194.0, accuracy: 0.002)
        if orientation == .portrait { XCTAssertEqual(paper.frame, originalPaper) }
      }
    }
  }

  func testNotebookAcceptsTheNextTurnAsSoonAsThePreviousSheetLands() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)

    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    for page in 2...4 {
      surface.swipeLeft()
      // Begin the next contact after the actual native landing, not during
      // the previous curl based on an assumed 250-ms animation duration.
      wait(for: [XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value BEGINSWITH %@", "Страница \(page) из "), object: surface
      )], timeout: 3)
    }
    XCTAssertEqual(app.state, .runningForeground)
  }

  func testDocumentPageTurnShowsTheCommittedPhysicalPage() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture",
    ]
    launchPortraitFixture(app)

    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 8))
    let paginationReady = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"
      ),
      object: surface
    )
    await fulfillment(of: [paginationReady], timeout: 8)
    try await Task.sleep(for: .seconds(2.5))
    surface.swipeLeft()

    let landed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"),
      object: surface
    )
    await fulfillment(of: [landed], timeout: 3)

    let secondText = try visibleDocumentText(app: app, surface: surface, name: "document-page-2")
    surface.swipeLeft()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 3 из '"), object: surface
    )], timeout: 3)
    try await Task.sleep(for: .milliseconds(600))
    let thirdText = try visibleDocumentText(app: app, surface: surface, name: "document-page-3")
    XCTAssertNotEqual(secondText, thirdText, "Соседние листы показывают разные фрагменты текста")
    surface.swipeRight()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"), object: surface
    )], timeout: 3)
    try await Task.sleep(for: .milliseconds(600))
    let returnedText = try visibleDocumentText(app: app, surface: surface, name: "document-page-2-return")
    let sections = try NSRegularExpression(pattern: #"Раздел\s+(\d+)"#)
    func sectionIDs(_ text: String) -> [String] {
      sections.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range(at: 1), in: text)!])
      }
    }
    XCTAssertGreaterThanOrEqual(sectionIDs(secondText).count, 4)
    XCTAssertNotEqual(sectionIDs(secondText), sectionIDs(thirdText))
    XCTAssertEqual(sectionIDs(secondText), sectionIDs(returnedText),
      "Возврат восстанавливает содержание того же листа")
  }

  func testCompactPageControlsKeepFullTargetsAndOpenOverviewAndSearch() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture", "--notebook-document-prose-fixture"]
    launchPortraitFixture(app)
    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout:8))
    func landed(_ page: Int) async {
      await fulfillment(of:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"value BEGINSWITH %@", "Страница \(page) из "),object:surface)],timeout:5)
    }
    func edgeTap(_ id: String, width: CGFloat = 44) {
      let button = app.buttons[id]
      XCTAssertEqual(button.frame.width,width,accuracy:1); XCTAssertEqual(button.frame.height,44,accuracy:1)
      button.coordinate(withNormalizedOffset:.init(dx:0.1,dy:0.1)).tap()
    }
    await fulfillment(of:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"),object:surface)],timeout:5)
    edgeTap("next-page"); await landed(2)
    edgeTap("page-overview",width:64)
    let third = app.buttons["Страница 3"]
    XCTAssertTrue(third.waitForExistence(timeout:5))
    let proof = XCTAttachment(screenshot:app.screenshot()); proof.name = "compact-page-overview"; proof.lifetime = .keepAlways; add(proof)
    third.tap(); await landed(3)
    let folio = XCTAttachment(screenshot:app.screenshot()); folio.name = "paper-page-folio"; folio.lifetime = .keepAlways; add(folio)
    edgeTap("previous-page"); await landed(2)
    edgeTap("notebook-search")
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout:3))
    app.buttons["Готово"].tap()
    XCTAssertTrue(app.searchFields.firstMatch.waitForNonExistence(timeout:3)); await landed(2)
    edgeTap("previous-page"); await landed(1)
    app.terminate()
  }

  func testPageControlsAndSearchReturnToTheReadPage() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture", "--notebook-document-prose-fixture"]
    launchPortraitFixture(app)
    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 8))
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"), object: surface)], timeout: 5)
    let next = app.buttons["next-page"]
    XCTAssertEqual(next.frame.width,44,accuracy:1); XCTAssertEqual(next.frame.height,44,accuracy:1)
    next.coordinate(withNormalizedOffset:.init(dx:0.1,dy:0.1)).tap()
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"), object: surface)], timeout: 3)
    app.buttons["page-overview"].tap()
    let thumbnail = app.buttons["Страница 3"]
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
    try await Task.sleep(for: .seconds(2))
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "real-page-thumbnails"; proof.lifetime = .keepAlways; add(proof)
    thumbnail.tap()
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Страница 3 из '"), object: surface)], timeout: 3)
    app.buttons["notebook-search"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 3)); search.tap(); search.typeText("Глава 1")
    let result = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Глава 1'")).firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 5)); result.tap()
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из '"), object: surface)], timeout: 6)
    app.buttons["leave-nested-board"].tap()
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Страница 3 из '"), object: surface)], timeout: 5)
  }

  func testDocumentLinksOpenTheMeasuredDistantPageAndReturnToContents() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture", "--notebook-document-links-fixture", "--notebook-profile-documents"]
    launchPortraitFixture(app)
    func attachInstallation(_ name: String) {
      let records = app.descendants(matching: .any).matching(identifier: "document-runtime")
        .allElementsBoundByIndex.compactMap { $0.value as? String }
      let attachment = XCTAttachment(string: records.joined(separator: "\n"))
      attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    let surface = app.otherElements["page-turn-surface"]
    let outward = app.links["К дальней главе"].firstMatch
    XCTAssertTrue(outward.waitForExistence(timeout: 8))
    XCTAssertTrue(outward.isHittable)
    outward.tap()
    let returning = app.links["К оглавлению"].firstMatch
    XCTAssertTrue(returning.waitForExistence(timeout: 5), "A link must mount its off-page destination, not scroll the current fragment")
    XCTAssertTrue(returning.isHittable)
    XCTAssertFalse((surface.value as? String ?? "").hasPrefix("Страница 1 из "))
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "document-link-distant-page"; proof.lifetime = .keepAlways; add(proof)
    attachInstallation("distant-page-installation")
    returning.tap()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из '"), object: surface)], timeout: 5)
    attachInstallation("return-page-installation")
    XCTAssertTrue(outward.waitForExistence(timeout: 3)); XCTAssertTrue(outward.isHittable)
    XCTAssertFalse(app.textViews["Исходный Markdown или LaTeX"].exists, "Following links must not start source editing")
    app.links["Отсутствующий раздел"].firstMatch.tap()
    XCTAssertTrue(app.alerts["Ссылка недоступна"].waitForExistence(timeout: 2))
    app.alerts.buttons["Понятно"].tap()
    XCTAssertTrue((surface.value as? String ?? "").hasPrefix("Страница 1 из "))
  }

  func testDocumentFarLinkEditSaveAndColdReopeningKeepTheVisibleSavedText() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures",
      "--notebook-document-runtime-fixture", "--notebook-document-links-fixture"]
    launchPortraitFixture(app)
    let outward = app.links["К дальней главе"].firstMatch
    XCTAssertTrue(outward.waitForExistence(timeout: 8)); outward.tap()
    let returning = app.links["К оглавлению"].firstMatch
    XCTAssertTrue(returning.waitForExistence(timeout: 5)); returning.tap()
    let firstPage = app.otherElements["page-turn-page-0"].firstMatch
    let heading = firstPage.staticTexts["Оглавление проверки"].firstMatch
    XCTAssertTrue(heading.waitForExistence(timeout: 5)); heading.doubleTap()
    let editor = app.textViews["Исходный Markdown или LaTeX"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    editor.typeText("\n\nСохранено до закрытия\n\n")
    XCTAssertTrue((editor.value as? String)?.contains("Сохранено до закрытия") == true)
    app.buttons["Сохранить"].firstMatch.tap()
    let saved = firstPage.staticTexts["Сохранено до закрытия"].firstMatch
    XCTAssertTrue(saved.waitForExistence(timeout: 12), "Save must install the new readable text before closing")
    XCTAssertFalse(editor.exists)
    let installed = XCTAttachment(screenshot: app.screenshot())
    installed.name = "full-document-cycle-saved-before-close"; installed.lifetime = .keepAlways; add(installed)
    app.buttons["leave-nested-board"].tap()
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))
    app.terminate()
    app.launchArguments.append("--notebook-reopen-fixture")
    launchPortraitFixture(app)
    let cover = app.descendants(matching: .any).matching(
      identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000006").firstMatch
    XCTAssertTrue(cover.waitForExistence(timeout: 5)); cover.doubleTap()
    XCTAssertTrue(saved.waitForExistence(timeout: 8), "A fresh process must read the saved source from SQLite")
    XCTAssertFalse(editor.exists)
    XCTAssertTrue(outward.waitForExistence(timeout: 3)); outward.tap()
    XCTAssertTrue(returning.waitForExistence(timeout: 5)); returning.tap()
    XCTAssertTrue(saved.waitForExistence(timeout: 5), "Reopened anchors and the saved first page must still agree")
    let reopened = XCTAttachment(screenshot: app.screenshot())
    reopened.name = "full-document-cycle-cold-reopened"; reopened.lifetime = .keepAlways; add(reopened)
    // The page container extends behind the status bar; XCTest chooses its
    // top hit point for multi-touch. Target visible paper text, not that inset.
    heading.tap(withNumberOfTaps: 1, numberOfTouches: 2)
    let undone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !saved.exists }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [undone], timeout: 8), .completed,
      "The ordinary two-finger undo must restore the saved document action after a cold reopening")
    XCTAssertTrue(heading.exists, "Undo restores the block; it must not navigate away or remove the paper")
    let undoImage = XCTAttachment(screenshot: app.screenshot())
    undoImage.name = "document-source-undo-after-cold-reopening"; undoImage.lifetime = .keepAlways; add(undoImage)
    app.terminate()
  }

  func testProseDocumentTurnsToDifferentTextAndBack() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture", "--notebook-document-prose-fixture"]
    launchPortraitFixture(app)
    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 8))
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"),
      object: surface)], timeout: 4)
    try await Task.sleep(for: .seconds(2.5))
    let first = try visibleDocumentText(app: app, surface: surface, name: "prose-page-1")
    surface.swipeLeft()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"), object: surface
    )], timeout: 3)
    try await Task.sleep(for: .milliseconds(600))
    let second = try visibleDocumentText(app: app, surface: surface, name: "prose-page-2")
    XCTAssertNotEqual(first, second)
    XCTAssertFalse(second.contains("Глава 1"), "Первый заголовок остаётся на первом листе")
    surface.swipeLeft()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 3 из '"), object: surface
    )], timeout: 3)
    try await Task.sleep(for: .milliseconds(600))
    let third = try visibleDocumentText(app: app, surface: surface, name: "prose-page-3")
    XCTAssertFalse(third.contains("Глава 1"))
    surface.swipeRight()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"), object: surface
    )], timeout: 3)
    surface.swipeRight()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из '"), object: surface
    )], timeout: 3)
    try await Task.sleep(for: .milliseconds(600))
    let returned = try visibleDocumentText(app: app, surface: surface, name: "prose-page-1-return")
    XCTAssertTrue(returned.contains("Глава 1"))
    let topics = try NSRegularExpression(pattern: #"[1-3]\.[1-4]"#)
    func topicIDs(_ text: String) -> [String] {
      topics.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range, in: text)!])
      }
    }
    XCTAssertGreaterThanOrEqual(topicIDs(first).count, 4)
    XCTAssertEqual(topicIDs(first), topicIDs(returned))
  }

  private func workspaceWindow(in app: XCUIApplication) -> XCUIElement {
    app.windows.containing(.button, identifier: "pen-controls-toggle").firstMatch
  }

  private func openChat(in app: XCUIApplication) {
    let compose = app.buttons["notebook-companion-compose"]
    XCTAssertTrue(compose.waitForExistence(timeout: 3))
    compose.tap()
    XCTAssertTrue(app.buttons["notebook-chat-toggle"].waitForExistence(timeout: 3))
  }

  private func openSharedHistory(in app: XCUIApplication) {
    let menu = app.buttons["notebook-chat-menu"]
    if !menu.exists { app.buttons["notebook-companion-compose"].tap() }
    XCTAssertTrue(menu.waitForExistence(timeout: 3))
    menu.tap()
    XCTAssertTrue(app.buttons["Совместные ходы"].waitForExistence(timeout: 3))
    app.buttons["Совместные ходы"].tap()
  }

  private func launchPortraitFixture(_ app: XCUIApplication) {
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    let window = workspaceWindow(in: app)
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard window.exists else { return false }
      let frame = window.frame
      return frame.width > 0 && frame.height > frame.width && frame.origin == .zero
    }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed,
      "The real workspace, not an offscreen preparation window, owns the portrait fixture")
  }

  private func visibleDocumentText(app: XCUIApplication, surface: XCUIElement, name: String) throws -> String {
    let screenshot = app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["ru-RU"]
    let frame = surface.frame.intersection(app.frame)
    let pageRegion = CGRect(x: (frame.minX - app.frame.minX) / app.frame.width,
      y: 1 - (frame.maxY - app.frame.minY) / app.frame.height,
      width: frame.width / app.frame.width, height: frame.height / app.frame.height)
    try VNImageRequestHandler(cgImage: screenshot.image.cgImage!, options: [:]).perform([request])
    // Recognize complete screen glyphs, then address observations to the real
    // sheet. Cropping the recognizer's input changes its word segmentation.
    let text = (request.results ?? []).filter {
      pageRegion.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY))
    }.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    XCTAssertFalse(text.isEmpty)
    let proof = XCTAttachment(string: text); proof.name = name + "-text"; proof.lifetime = .keepAlways; add(proof)
    return text
  }

  func testPageFitSurvivesPortraitLandscapePortrait() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(450))
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let original = paper.frame

    XCUIDevice.shared.orientation = .landscapeLeft
    try await Task.sleep(for: .milliseconds(700))
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(900))

    let restored = paper.frame
    XCTAssertEqual(restored.midX, original.midX, accuracy: 2)
    XCTAssertEqual(restored.midY, original.midY, accuracy: 2)
    XCTAssertEqual(restored.width, original.width, accuracy: 2)
    XCTAssertEqual(restored.height, original.height, accuracy: 2)
  }

  func testZoomCannotEnterOrLeaveTheNotebookButDoubleTapAndBackCan() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures", "--notebook-page-turn-content-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let original = paper.frame
    let marker = app.otherElements["agent-element-page-marker-0"]
    XCTAssertTrue(marker.waitForExistence(timeout: 5))
    marker.pinch(withScale: 0.28, velocity: -2)
    XCTAssertTrue(paper.exists)
    XCTAssertTrue(marker.exists, "Zoom must retain the same physical page")
    XCTAssertEqual(paper.frame.width, original.width, accuracy: 2, "The open sheet must stay fitted, not recede into the board")
    XCTAssertEqual(paper.frame.midX, original.midX, accuracy: 2)
    XCTAssertEqual(paper.frame.midY, original.midY, accuracy: 2)
    XCTAssertFalse(app.buttons["create-workspace-item"].exists)
    XCTAssertTrue(app.buttons["next-page"].exists)
    app.buttons["next-page"].tap()
    XCTAssertTrue(app.otherElements["agent-element-page-marker-1"].waitForExistence(timeout: 5))
    app.buttons["previous-page"].tap()
    XCTAssertTrue(marker.waitForExistence(timeout: 5))
    app.buttons["leave-nested-board"].tap()
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))
    let notebook = app.descendants(matching: .any).matching(
      identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002").firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    notebook.pinch(withScale: 1.5, velocity: 0.7)
    XCTAssertFalse(paper.exists, "Zooming toward a cover cannot open it")
    XCTAssertTrue(app.buttons["create-workspace-item"].exists)
    notebook.doubleTap()
    XCTAssertTrue(paper.waitForExistence(timeout: 3))
    XCTAssertTrue(marker.exists)
    XCTAssertEqual(paper.frame.midX, original.midX, accuracy: 2)
    XCTAssertEqual(paper.frame.midY, original.midY, accuracy: 2)
    XCTAssertEqual(paper.frame.width, original.width, accuracy: 2)
    XCTAssertEqual(paper.frame.height, original.height, accuracy: 2)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "explicit-notebook-entry-after-zoom-and-page-turn"; proof.lifetime = .keepAlways; add(proof)
  }

  func testNotebookPinchesZoomTheOpenSheetInsteadOfItsCover() throws {
    try checkOpenSheetPinches(document: false)
  }

  func testDocumentPinchesZoomTheOpenSheetInsteadOfItsCover() throws {
    try checkOpenSheetPinches(document: true)
  }

  private func checkOpenSheetPinches(document: Bool) throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-simulator-finger-gestures"]
    app.launchArguments.append(document ? "--notebook-document-runtime-fixture" : "--notebook-page-turn-content-fixture")
    launchPortraitFixture(app)
    let sheet = app.otherElements[document ? "page-turn-surface" : "paper-input"].firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 8))
    let fitted = sheet.frame
    // Full-window XCTest pinch starts one finger on the top-left Back button.
    // Use real visible content so both contacts belong to the paper.
    let gestureSurface = document
      ? sheet.staticTexts["Документ соединяет текст, формулы и управление."].firstMatch
      : app.otherElements["agent-element-page-marker-0"]
    XCTAssertTrue(gestureSurface.waitForExistence(timeout: 5))
    let item = app.descendants(matching: .any).matching(identifier:
      "workspace-item-7e7a1000-0000-4000-8000-00000000000\(document ? 6 : 2)").firstMatch
    let cover = item.otherElements["cover-opening-surface"].firstMatch
    func assertOpen(_ name: String) {
      let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      proof.name = name; proof.lifetime = .keepAlways; add(proof)
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
      XCTAssertTrue(sheet.waitForExistence(timeout: 2))
      XCTAssertEqual(cover.value as? String, "Обложка 100%", "The same sheet must stay fully open during ordinary zoom")
      XCTAssertFalse(app.buttons["create-workspace-item"].exists)
      XCTAssertFalse(app.textViews["Исходный Markdown или LaTeX"].exists,
        "The two releases of a pinch are not a double tap on document text")
      XCTAssertFalse(app.keyboards.firstMatch.exists)
    }
    for attempt in 0..<2 {
      gestureSurface.pinch(withScale: 0.28, velocity: -2)
      assertOpen("paper-strong-reduction-\(document)-\(attempt)")
      XCTAssertEqual(sheet.frame.width, fitted.width, accuracy: 2, "Zoom-out must stop at the whole sheet")
      XCTAssertEqual(sheet.frame.height, fitted.height, accuracy: 2)
      XCTAssertEqual(sheet.frame.midX, fitted.midX, accuracy: 2)
      XCTAssertEqual(sheet.frame.midY, fitted.midY, accuracy: 2)
    }
    gestureSurface.pinch(withScale: 1.6, velocity: 0.7)
    assertOpen("paper-enlarged-\(document)")
    XCTAssertGreaterThan(sheet.frame.width, fitted.width * 1.1,
      "Lifting the pair must retain real paper magnification, not snap back to fit")
    gestureSurface.pinch(withScale: 0.94, velocity: -0.2)
    assertOpen("paper-zoom-retained-\(document)")
    XCTAssertGreaterThan(sheet.frame.width, fitted.width * 1.05)
  }

  func testDoubleTapOpensAWholePageImmediately() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
    ]
    launchPortraitFixture(app)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let originalPaperFrame = paper.frame
    app.buttons["leave-nested-board"].tap()
    let boardShown = app.buttons["create-workspace-item"].waitForExistence(timeout: 5)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "after-pinch-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    let pixels = XCTAttachment(screenshot: app.screenshot())
    pixels.name = "after-pinch-pixels"; pixels.lifetime = .keepAlways; add(pixels)
    XCTAssertTrue(boardShown)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    let openedAt = Date()
    notebook.doubleTap()

    XCTAssertTrue(paper.waitForExistence(timeout: 3))
    XCTAssertEqual(paper.frame.midX, originalPaperFrame.midX, accuracy: 2)
    XCTAssertEqual(paper.frame.midY, originalPaperFrame.midY, accuracy: 2)
    XCTAssertEqual(paper.frame.width, originalPaperFrame.width, accuracy: 2)
    XCTAssertEqual(paper.frame.height, originalPaperFrame.height, accuracy: 2)
    let opened = XCTAttachment(screenshot: app.screenshot())
    opened.name = "notebook-opened-within-3-seconds"; opened.lifetime = .keepAlways; add(opened)
    let duration = XCTAttachment(string: "Double tap and whole paper readiness: \(Date().timeIntervalSince(openedAt)) seconds")
    duration.name = "notebook-opening-duration"; duration.lifetime = .keepAlways; add(duration)
  }

  func testCreatesAndEntersBoardsAtTwoNestedLevels() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
    ]
    launchPortraitFixture(app)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    app.buttons["leave-nested-board"].tap()
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))

    func createAndEnterBoard() {
      let items = app.descendants(matching: .any).matching(
        NSPredicate(format: "identifier BEGINSWITH 'workspace-item-'")
      )
      let before = Set(items.allElementsBoundByIndex.map(\.identifier))
      app.buttons["create-workspace-item"].tap()
      let createBoard = app.buttons["create-nested-board"]
      XCTAssertTrue(createBoard.waitForExistence(timeout: 2))
      createBoard.tap()

      // Publication is asynchronous. Resolve the newly created physical owner,
      // never the last old item or an unsigned index computed from an empty list.
      let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        !Set(items.allElementsBoundByIndex.map(\.identifier)).subtracting(before).isEmpty
      }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 3), .completed)
      XCTAssertFalse(app.staticTexts["persistence-failure"].firstMatch.exists)
      let identifier = Set(items.allElementsBoundByIndex.map(\.identifier)).subtracting(before).sorted().first
      guard let identifier else { return XCTFail("Созданная доска не опубликована") }
      let portal = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
      portal.doubleTap()
      XCTAssertTrue(app.buttons["leave-nested-board"].waitForExistence(timeout: 3))
      XCTAssertTrue(app.buttons["create-workspace-item"].exists)
    }

    createAndEnterBoard()
    createAndEnterBoard()

    app.buttons["leave-nested-board"].tap()
    XCTAssertTrue(app.buttons["leave-nested-board"].waitForExistence(timeout: 2))
    app.buttons["leave-nested-board"].tap()
    XCTAssertTrue(app.buttons["leave-nested-board"].waitForNonExistence(timeout: 2))
    XCTAssertTrue(app.buttons["create-workspace-item"].exists)
    let portalProof = XCTAttachment(screenshot: app.screenshot())
    portalProof.name = "nested-board-live-portal"
    portalProof.lifetime = .keepAlways
    add(portalProof)
  }

  func testZoomCannotEnterOrLeaveABoardButDoubleTapAndBackCan() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures", "--notebook-nested-board-fixture"]
    launchPortraitFixture(app)
    // Navigation gets an existing two-level workspace; the Create menu is a
    // separate scenario, not a prerequisite for exercising the camera owner.
    let portal = app.descendants(matching: .any).matching(identifier:
      "workspace-item-7e7a1000-0000-4000-8000-00000000000d").firstMatch
    XCTAssertTrue(portal.waitForExistence(timeout: 5))
    portal.pinch(withScale: 3, velocity: 2)
    XCTAssertTrue(portal.exists, "Zoom cannot replace a portal with its child board")
    portal.pinch(withScale: 1.0 / 3.0, velocity: -2)
    XCTAssertTrue(portal.exists)
    portal.doubleTap()
    XCTAssertTrue(portal.waitForNonExistence(timeout: 4), "Only explicit entry changes the board")
    XCTAssertTrue(app.buttons["leave-nested-board"].waitForExistence(timeout: 4))

    // Pinch a real child cover rather than the entire UIWindow: its bottom
    // corner is the Create control, which correctly owns that finger itself.
    let cover = app.descendants(matching: .any).matching(identifier:
      "workspace-item-7e7a1000-0000-4000-8000-000000000002").firstMatch
    XCTAssertTrue(cover.waitForExistence(timeout: 3))
    cover.pinch(withScale: 0.55, velocity: -2)
    XCTAssertFalse(portal.exists)
    XCTAssertTrue(cover.exists)
    cover.pinch(withScale: 0.35, velocity: -2)
    XCTAssertFalse(portal.exists, "Even repeated zoom-out below the entry scale cannot leave the board")
    XCTAssertTrue(cover.exists, "The same child material remains on the current board")
    app.buttons["leave-nested-board"].tap()
    XCTAssertTrue(portal.waitForExistence(timeout: 4))
    XCTAssertLessThan(portal.frame.width, workspaceWindow(in: app).frame.width)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "parent-portal-after-explicit-back-not-zoom"; proof.lifetime = .keepAlways; add(proof)
  }

  func testDoubleTapOpensAnAlreadyFocusedCoverWithoutStartingTextEditing() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures", "--notebook-nearby-cover-fixture"]
    launchPortraitFixture(app)
    let notebook = app.descendants(matching: .any).matching(
      identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002").firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 5))
    notebook.tap()
    XCTAssertFalse(app.otherElements["paper-input"].exists)
    notebook.doubleTap()
    XCTAssertTrue(app.otherElements["paper-input"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "native-text-editor").firstMatch.exists)
  }

  func testSingleTapOffersDeletionAndRepairsAStack() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-stacked-board-fixture",
    ]
    launchPortraitFixture(app)
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))

    let removed = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000004"
      )
      .firstMatch
    let remaining = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(removed.waitForExistence(timeout: 3))
    XCTAssertTrue(remaining.exists)

    removed.tap()
    let delete = app.buttons["delete-workspace-item"]
    XCTAssertTrue(delete.waitForExistence(timeout: 2))

    workspaceWindow(in: app).coordinate(
      withNormalizedOffset: CGVector(dx: 0.04, dy: 0.08)
    ).tap()
    XCTAssertFalse(
      delete.waitForExistence(timeout: 0.6),
      "Касание свободной доски должно снять выбор"
    )

    removed.tap()
    XCTAssertTrue(delete.waitForExistence(timeout: 2))
    XCTAssertEqual(delete.frame.width,44,accuracy:1); XCTAssertEqual(delete.frame.height,44,accuracy:1)
    let open = app.buttons["open-workspace-item"]
    XCTAssertTrue(open.exists); XCTAssertEqual(open.frame.midY,delete.frame.midY,accuracy:1)
    XCTAssertEqual(delete.frame.minX-open.frame.minX,44,accuracy:1)
    let capsule = XCTAttachment(screenshot:app.screenshot())
    capsule.name = "workspace-item-shared-capsule"; capsule.lifetime = .keepAlways; add(capsule)
    // The common capsule keeps full 44-point targets, including beside the glyph.
    delete.coordinate(withNormalizedOffset:.init(dx:0.25,dy:0.5)).tap()

    XCTAssertTrue(remaining.waitForExistence(timeout: 2))
    XCTAssertFalse(removed.exists)
  }

  func testSharedCapsuleOpensSelectedNotebook() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture","--notebook-stacked-board-fixture"]
    launchPortraitFixture(app)
    let card = app.descendants(matching:.any).matching(
      identifier:"workspace-item-7e7a1000-0000-4000-8000-000000000004").firstMatch
    XCTAssertTrue(card.waitForExistence(timeout:5)); card.tap()
    let open = app.buttons["open-workspace-item"], remove = app.buttons["delete-workspace-item"]
    XCTAssertTrue(open.waitForExistence(timeout:3)); XCTAssertTrue(remove.isHittable)
    XCTAssertEqual(open.frame.width,44,accuracy:1); XCTAssertEqual(open.frame.height,44,accuracy:1)
    XCTAssertEqual(remove.frame.midY,open.frame.midY,accuracy:1)
    XCTAssertFalse(app.buttons["graphic-style-menu"].exists)
    let proof = XCTAttachment(screenshot:app.screenshot())
    proof.name = "shared-capsule-notebook"; proof.lifetime = .keepAlways; add(proof)
    open.tap()
    XCTAssertTrue(open.waitForNonExistence(timeout:5))
    XCTAssertTrue(app.otherElements["paper-input"].waitForExistence(timeout:5))
    app.terminate()
  }

  func testImmediateDragFromACoverPansTheWholeBoard() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-stacked-board-fixture",
    ]
    launchPortraitFixture(app)

    let covers = ["002", "004"].map { suffix in
      app.descendants(matching: .any).matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000\(suffix)"
      ).firstMatch
    }
    for cover in covers { XCTAssertTrue(cover.waitForExistence(timeout: 5)) }
    let initial = covers.map(\.frame)
    for delta in [CGVector(dx: 120, dy: 80), CGVector(dx: -90, dy: -50)] {
      let before = covers.map(\.frame)
      let start = covers[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.01, thenDragTo: start.withOffset(delta),
        withVelocity: .fast, thenHoldForDuration: 0)
      for (cover, frame) in zip(covers, before) {
        XCTAssertEqual(cover.frame.midX - frame.midX, delta.dx, accuracy: 6,
          "Движение с обложки должно сдвигать всю доску вместе с соседями")
        XCTAssertEqual(cover.frame.midY - frame.midY, delta.dy, accuracy: 6)
        XCTAssertEqual(cover.frame.width, frame.width, accuracy: 2)
      }
    }
    for (cover, frame) in zip(covers, initial) {
      XCTAssertEqual(cover.frame.midX - frame.midX, 30, accuracy: 6)
      XCTAssertEqual(cover.frame.midY - frame.midY, 30, accuracy: 6)
    }
    XCTAssertFalse(app.buttons["delete-workspace-item"].exists,
      "Завершённое движение камеры оставляет выбор у сцены")
  }

  func testLongPressPicksUpAndMovesTheNotebook() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-cover-eraser-fixture",
    ]
    launchPortraitFixture(app)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 5))
    let initialFrame = notebook.frame
    let start = notebook.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
    )
    let end = start.withOffset(CGVector(dx: 120, dy: 80))

    start.press(
      forDuration: 0.28,
      thenDragTo: end,
      withVelocity: .slow,
      thenHoldForDuration: 0
    )

    let moved = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        block: { object, _ in
          guard let element = object as? XCUIElement else { return false }
          return element.frame.midX > initialFrame.midX + 70
            && element.frame.midY > initialFrame.midY + 40
        }
      ),
      object: notebook
    )
    wait(for: [moved], timeout: 2)

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "cover-ink-after-notebook-move"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testCoverAndBoardAcceptConsecutivePencilActions() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-nearby-cover-fixture",
    ]
    launchPortraitFixture(app)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    let ink = app.otherElements["spatial-ink"]
    XCTAssertTrue(notebook.waitForExistence(timeout: 5))
    XCTAssertTrue(ink.waitForExistence(timeout: 2))
    XCTAssertEqual(ink.value as? String, "0 действий")

    notebook.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
      .press(
        forDuration: 0.04,
        thenDragTo: notebook.coordinate(
          withNormalizedOffset: CGVector(dx: 0.72, dy: 0.42)
        ),
        withVelocity: .slow,
        thenHoldForDuration: 0
      )
    let firstCommitted = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "1 действий"),
      object: ink
    )
    wait(for: [firstCommitted], timeout: 2)

    let window = workspaceWindow(in: app)
    XCTAssertTrue(window.exists)
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.18))
      .press(
        forDuration: 0.04,
        thenDragTo: window.coordinate(
          withNormalizedOffset: CGVector(dx: 0.08, dy: 0.52)
        ),
        withVelocity: .slow,
        thenHoldForDuration: 0
      )
    let secondCommitted = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "2 действий"),
      object: ink
    )
    wait(for: [secondCommitted], timeout: 2)
  }

  func testCoverEraserCommitsIntoTheVisibleSpatialScene() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-cover-eraser-fixture",
    ]
    launchPortraitFixture(app)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    let ink = app.otherElements["spatial-ink"]
    XCTAssertTrue(notebook.waitForExistence(timeout: 5))
    XCTAssertTrue(ink.waitForExistence(timeout: 2))
    XCTAssertEqual(ink.value as? String, "1 действий")

    notebook.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.42))
      .press(
        forDuration: 0.04,
        thenDragTo: notebook.coordinate(
          withNormalizedOffset: CGVector(dx: 0.82, dy: 0.42)
        ),
        withVelocity: .slow,
        thenHoldForDuration: 0
      )

    let erased = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "2 действий"),
      object: ink
    )
    wait(for: [erased], timeout: 2)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "cover-eraser"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testUnrevealedCoverKeepsTheReleasedBoardCamera() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-off-center-cover-fixture",
    ]
    launchPortraitFixture(app)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    let coverFrame = notebook.frame
    let window = workspaceWindow(in: app)
    XCTAssertTrue(window.exists)
    let coverOffset = abs(coverFrame.midX - window.frame.midX)
    XCTAssertGreaterThan(coverOffset, 80)

    notebook.pinch(withScale: 1.005, velocity: 0.05)
    try await Task.sleep(for: .milliseconds(300))
    let releasedFrame = notebook.frame

    XCTAssertEqual(releasedFrame.width, coverFrame.width, accuracy: 3)
    XCTAssertEqual(releasedFrame.height, coverFrame.height, accuracy: 3)
    XCTAssertFalse(app.otherElements["paper-input"].exists)

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "unrevealed-cover-keeps-board-camera"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testDoubleTapCentersAnOffCenterNotebookWithItsOpening() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-off-center-cover-fixture",
    ]
    launchPortraitFixture(app)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    let window = workspaceWindow(in: app)
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    XCTAssertTrue(window.exists)
    notebook.doubleTap()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(
      paper.waitForExistence(timeout: 3),
      "Двойное нажатие должно завершить раскрытие"
    )
    try await Task.sleep(for: .milliseconds(320))
    assertFittedAndCentered(paper.frame, in: window.frame)

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "double-tap-opening-centers-notebook"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testCoverInkTravelsWithThePhysicalCurl() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-cover-eraser-fixture",
      "--notebook-partial-cover-fixture",
    ]
    launchPortraitFixture(app)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    try await Task.sleep(for: .milliseconds(300))

    let curl = app.otherElements["cover-opening-surface"]
    XCTAssertTrue(curl.exists)
    XCTAssertNotEqual(
      curl.value as? String,
      "Обложка 0%",
      "Проверка должна видеть именно частично изгибающуюся обложку"
    )
    XCTAssertFalse(app.otherElements["paper-input"].exists)
    XCTAssertEqual(app.state, .runningForeground)
    let screenshot = app.screenshot()
    let proof = XCTAttachment(screenshot: screenshot)
    proof.name = "cover-ink-on-physical-curl"
    proof.lifetime = .keepAlways
    add(proof)
    XCTAssertGreaterThan(
      visibleInkPixelShare(
        in: screenshot,
        normalizedRect: CGRect(x: 0.16, y: 0.34, width: 0.26, height: 0.18)
      ),
      0.005,
      "Устойчивые чернила должны остаться видимыми под изгибающейся обложкой"
    )
    let technicalBand = CGRect(
      x: notebook.frame.minX + notebook.frame.width * 0.29,
      y: notebook.frame.minY - 12,
      width: notebook.frame.width * 0.36,
      height: 9
    )
    let window = workspaceWindow(in: app)
    XCTAssertTrue(window.exists)
    XCTAssertLessThan(
      opaqueGrayPixelShare(
        in: screenshot,
        normalizedRect: CGRect(
          x: (technicalBand.minX - window.frame.minX) / window.frame.width,
          y: (technicalBand.minY - window.frame.minY) / window.frame.height,
          width: technicalBand.width / window.frame.width,
          height: technicalBand.height / window.frame.height
        )
      ),
      0.05,
      "The physical curl keeps its overscan transparent around the fold"
    )
  }

  func testDocumentClosesOnlyWithBackAndReopensByDoubleTap() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures", "--notebook-document-runtime-fixture"]
    launchPortraitFixture(app)
    let page = app.otherElements["page-turn-surface"]
    XCTAssertTrue(page.waitForExistence(timeout: 8))
    let content = page.staticTexts["Документ соединяет текст, формулы и управление."].firstMatch
    XCTAssertTrue(content.waitForExistence(timeout: 5))
    content.pinch(withScale: 0.28, velocity: -2)
    XCTAssertTrue(page.exists)
    XCTAssertFalse(app.buttons["create-workspace-item"].exists)
    app.buttons["leave-nested-board"].tap()
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))
    let document = app.descendants(matching: .any).matching(
      identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000006").firstMatch
    XCTAssertTrue(document.waitForExistence(timeout: 3))
    document.doubleTap()
    XCTAssertTrue(content.waitForExistence(timeout: 5))
  }

  func testDocumentCoverAndPaperKeepOneRectangleInBothOrientations() async throws {
    continueAfterFailure = false
    defer { XCUIDevice.shared.orientation = .portrait }
    for letter in [false, true] {
      XCUIDevice.shared.orientation = .portrait
      let app = XCUIApplication()
      app.launchArguments = [
        "--notebook-drawing-responsiveness-fixture",
        "--notebook-simulator-finger-gestures",
        "--notebook-document-runtime-fixture",
      ] + (letter ? ["--notebook-document-letter-fixture"] : [])
      launchPortraitFixture(app)
      for landscape in [false, true] {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        try await Task.sleep(for: .milliseconds(600))
        let document = app.descendants(matching: .any).matching(
          identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000006"
        ).firstMatch
        let paper = app.otherElements.matching(
          NSPredicate(format: "label BEGINSWITH 'Страница 1 из '")
        ).firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 8))
        let ratio = letter ? 612.0 / 792 : 595.275590551 / 841.88976378
        let surface = app.otherElements["page-turn-surface"]
        // The native sheet owns the landing rectangle; remote WebKit
        // accessibility frames round the ancestor transform to screen points.
        XCTAssertEqual(surface.frame.width / surface.frame.height, ratio, accuracy: 0.002)
        if abs(paper.frame.width - surface.frame.width) > 2 {
          let hierarchy = XCTAttachment(string: app.debugDescription)
          hierarchy.name = "document-frame-failure-hierarchy"
          hierarchy.lifetime = .keepAlways
          add(hierarchy)
        }
        XCTAssertEqual(paper.frame.width, surface.frame.width, accuracy: 2)
        XCTAssertEqual(paper.frame.height, surface.frame.height, accuracy: 2)
        XCTAssertEqual(paper.frame.midX, surface.frame.midX, accuracy: 2)
        XCTAssertEqual(paper.frame.midY, surface.frame.midY, accuracy: 2)
        let opened = surface.frame
        let openProof = XCTAttachment(screenshot: app.screenshot())
        openProof.name = "\(letter ? "letter" : "a4")-\(landscape ? "landscape" : "portrait")-paper"
        openProof.lifetime = .keepAlways
        add(openProof)
        app.buttons["leave-nested-board"].tap()
        XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))
        XCTAssertEqual(document.frame.width / document.frame.height, ratio, accuracy: 0.01)
        let coverProof = XCTAttachment(screenshot: app.screenshot())
        coverProof.name = "\(letter ? "letter" : "a4")-\(landscape ? "landscape" : "portrait")-cover"
        coverProof.lifetime = .keepAlways
        add(coverProof)
        document.doubleTap()
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(surface.frame.minX, opened.minX, accuracy: 2)
        XCTAssertEqual(surface.frame.minY, opened.minY, accuracy: 2)
        XCTAssertEqual(surface.frame.width, opened.width, accuracy: 2)
        XCTAssertEqual(surface.frame.height, opened.height, accuracy: 2)
      }
      app.terminate()
    }
  }

  func testDoubleTapApproachesTheNotebookWithoutAMagneticPinch() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-off-center-cover-fixture",
    ]
    launchPortraitFixture(app)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    let window = workspaceWindow(in: app)
    XCTAssertTrue(window.exists)
    XCTAssertGreaterThan(
      abs(notebook.frame.midX - window.frame.midX),
      80
    )
    XCTAssertGreaterThan(
      abs(notebook.frame.midY - window.frame.midY),
      50
    )
    notebook.doubleTap()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    try await Task.sleep(for: .milliseconds(350))
    assertFittedAndCentered(paper.frame, in: window.frame)
  }

  func testEachStackMemberOpensAsOneCenteredPage() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(350))

    try await assertCenteredStackMember(
      launchArgument: "--notebook-stacked-page-fixture",
      selectedID: "7e7a1000-0000-4000-8000-000000000004",
      hiddenSiblingID: "7e7a1000-0000-4000-8000-000000000002",
      attachmentName: "stacked-upper-page"
    )
    try await assertCenteredStackMember(
      launchArgument: "--notebook-stacked-lower-page-fixture",
      selectedID: "7e7a1000-0000-4000-8000-000000000002",
      hiddenSiblingID: "7e7a1000-0000-4000-8000-000000000004",
      attachmentName: "stacked-lower-page"
    )
  }

  func testStackMembersOpenFromTheBoardWithoutSplittingTheScreen() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(350))

    try await openStackMemberFromBoard(
      selectedID: "7e7a1000-0000-4000-8000-000000000004",
      hiddenSiblingID: "7e7a1000-0000-4000-8000-000000000002",
      attachmentName: "stacked-upper-double-tap"
    )
    try await openStackMemberFromBoard(
      selectedID: "7e7a1000-0000-4000-8000-000000000002",
      hiddenSiblingID: "7e7a1000-0000-4000-8000-000000000004",
      attachmentName: "stacked-lower-double-tap"
    )
  }

  private func openStackMemberFromBoard(
    selectedID: String,
    hiddenSiblingID: String,
    attachmentName: String
  ) async throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-stacked-board-fixture",
    ]
    launchPortraitFixture(app)
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))

    let selected = app.descendants(matching: .any)
      .matching(identifier: "workspace-item-\(selectedID)")
      .firstMatch
    let sibling = app.descendants(matching: .any)
      .matching(identifier: "workspace-item-\(hiddenSiblingID)")
      .firstMatch
    XCTAssertTrue(selected.waitForExistence(timeout: 3))
    XCTAssertTrue(sibling.exists)
    selected.doubleTap()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let window = workspaceWindow(in: app)
    XCTAssertTrue(window.exists)
    try await Task.sleep(for: .milliseconds(350))
    assertFittedAndCentered(paper.frame, in: window.frame)
    XCTAssertFalse(
      app.descendants(matching: .any)
        .matching(identifier: "workspace-item-\(hiddenSiblingID)")
        .firstMatch.exists,
      "После входа соседняя тетрадь должна остаться в стопке"
    )

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = attachmentName
    proof.lifetime = .keepAlways
    add(proof)
    app.terminate()
  }

  private func assertCenteredStackMember(
    launchArgument: String,
    selectedID: String,
    hiddenSiblingID: String,
    attachmentName: String
  ) async throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      launchArgument,
    ]
    launchPortraitFixture(app)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let window = workspaceWindow(in: app)
    XCTAssertTrue(window.exists)
    try await Task.sleep(for: .milliseconds(250))

    assertFittedAndCentered(paper.frame, in: window.frame)
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "workspace-item-\(selectedID)")
        .firstMatch.exists
    )
    XCTAssertFalse(
      app.descendants(matching: .any)
        .matching(identifier: "workspace-item-\(hiddenSiblingID)")
        .firstMatch.exists,
      "Соседняя тетрадь должна оставаться внутри стопки"
    )

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = attachmentName
    proof.lifetime = .keepAlways
    add(proof)
    app.terminate()
  }

  private func assertFittedAndCentered(_ paper: CGRect, in window: CGRect) {
    XCTAssertEqual(paper.midX, window.midX, accuracy: 2)
    XCTAssertEqual(paper.midY, window.midY, accuracy: 2)
    let fit = min(window.width / 834, window.height / 1_194)
    XCTAssertEqual(paper.width, 834 * fit, accuracy: 2)
    XCTAssertEqual(paper.height, 1_194 * fit, accuracy: 2)
  }

  private func darkPixelShare(
    in screenshot: XCUIScreenshot,
    normalizedRect: CGRect
  ) -> Double {
    pixelShare(in: screenshot, normalizedRect: normalizedRect) {
      red,
      green,
      blue,
      _ in
      max(red, green, blue) < 45
    }
  }

  private func visibleInkPixelShare(
    in screenshot: XCUIScreenshot,
    normalizedRect: CGRect
  ) -> Double {
    pixelShare(in: screenshot, normalizedRect: normalizedRect) {
      red,
      green,
      blue,
      _ in
      max(red, green, blue) < 180
    }
  }

  private func warmPaperPixelShare(
    in screenshot: XCUIScreenshot,
    normalizedRect: CGRect
  ) -> Double {
    pixelShare(in: screenshot, normalizedRect: normalizedRect) {
      red,
      green,
      blue,
      alpha in
      alpha > 240
        && red >= 245
        && green >= 243
        && blue <= 243
        && red >= blue + 4
    }
  }

  private func opaqueGrayPixelShare(
    in screenshot: XCUIScreenshot,
    normalizedRect: CGRect
  ) -> Double {
    pixelShare(in: screenshot, normalizedRect: normalizedRect) {
      red,
      green,
      blue,
      alpha in
      let darkest = min(red, green, blue)
      let lightest = max(red, green, blue)
      return alpha > 240
        && darkest >= 120
        && lightest <= 200
        && lightest - darkest <= 20
    }
  }

  private func pixelShare(
    in screenshot: XCUIScreenshot,
    normalizedRect: CGRect,
    matching predicate: (UInt8, UInt8, UInt8, UInt8) -> Bool
  ) -> Double {
    guard let image = screenshot.image.cgImage else {
      XCTFail("Снимок проверки должен содержать растровое изображение")
      return 0
    }

    let imageBounds = CGRect(
      x: 0,
      y: 0,
      width: image.width,
      height: image.height
    )
    let pixelRect = CGRect(
      x: normalizedRect.minX * imageBounds.width,
      y: normalizedRect.minY * imageBounds.height,
      width: normalizedRect.width * imageBounds.width,
      height: normalizedRect.height * imageBounds.height
    ).integral.intersection(imageBounds)
    guard !pixelRect.isEmpty, let crop = image.cropping(to: pixelRect) else {
      XCTFail("Область проверки чернил должна попадать в снимок")
      return 0
    }

    let bytesPerPixel = 4
    let bytesPerRow = crop.width * bytesPerPixel
    var pixels = [UInt8](
      repeating: 0,
      count: crop.height * bytesPerRow
    )
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress,
          width: crop.width,
          height: crop.height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.draw(
        crop,
        in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
      )
      return true
    }
    guard rendered else {
      XCTFail("Снимок проверки чернил должен читаться как RGBA")
      return 0
    }

    var matchingPixels = 0
    for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
      if predicate(
        pixels[offset],
        pixels[offset + 1],
        pixels[offset + 2],
        pixels[offset + 3]
      ) {
        matchingPixels += 1
      }
    }
    return Double(matchingPixels) / Double(crop.width * crop.height)
  }

  private func changedPixelShare(
    from first: XCUIScreenshot,
    to second: XCUIScreenshot,
    normalizedRect: CGRect
  ) -> Double {
    guard let firstImage = first.image.cgImage,
      let secondImage = second.image.cgImage,
      firstImage.width == secondImage.width,
      firstImage.height == secondImage.height
    else {
      XCTFail("Снимки листа должны иметь один размер")
      return 1
    }
    let imageBounds = CGRect(
      x: 0,
      y: 0,
      width: firstImage.width,
      height: firstImage.height
    )
    let pixelRect = CGRect(
      x: normalizedRect.minX * imageBounds.width,
      y: normalizedRect.minY * imageBounds.height,
      width: normalizedRect.width * imageBounds.width,
      height: normalizedRect.height * imageBounds.height
    ).integral.intersection(imageBounds)
    guard !pixelRect.isEmpty,
      let firstCrop = firstImage.cropping(to: pixelRect),
      let secondCrop = secondImage.cropping(to: pixelRect),
      let firstPixels = rgbaPixels(firstCrop),
      let secondPixels = rgbaPixels(secondCrop)
    else {
      XCTFail("Одинаковая область листа должна читаться с обоих снимков")
      return 1
    }

    let bytesPerPixel = 4
    var changedPixels = 0
    for offset in stride(
      from: 0,
      to: firstPixels.count,
      by: bytesPerPixel
    ) {
      let largestChannelChange = (0..<bytesPerPixel).reduce(0) { change, channel in
        max(
          change,
          abs(
            Int(firstPixels[offset + channel])
              - Int(secondPixels[offset + channel])
          )
        )
      }
      if largestChannelChange > 12 { changedPixels += 1 }
    }
    return Double(changedPixels)
      / Double(firstPixels.count / bytesPerPixel)
  }

  private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
    let bytesPerPixel = 4
    let bytesPerRow = image.width * bytesPerPixel
    var pixels = [UInt8](
      repeating: 0,
      count: image.height * bytesPerRow
    )
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return false }
      context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
      )
      return true
    }
    return rendered ? pixels : nil
  }

  func testPenCommitsOneStrokeAndKeepsThePaperResponsive() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-pen-persistence-fixture"]
    launchPortraitFixture(app)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    XCTAssertEqual(paper.value as? String, "80 действий пера")

    // Keep the stroke on exposed paper, below the compact chat controls.
    let start = paper.coordinate(
      withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)
    )
    let end = paper.coordinate(
      withNormalizedOffset: CGVector(dx: 0.82, dy: 0.57)
    )
    let dragStarted = ContinuousClock.now
    start.press(
      forDuration: 0.05,
      thenDragTo: end,
      withVelocity: .slow,
      thenHoldForDuration: 0
    )
    XCTAssertLessThan(
      ContinuousClock.now - dragStarted,
      .seconds(4),
      "Живой штрих не должен ждать PencilKit, файл или сеть"
    )

    let drawingChanged = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "81 действий пера"),
      object: paper
    )
    wait(for: [drawingChanged], timeout: 2)

    let controls = app.buttons["pen-controls-toggle"]
    XCTAssertTrue(controls.waitForExistence(timeout: 2))
    controls.tap()
    XCTAssertTrue(
      app.buttons["drawing-tool-eraser"].waitForExistence(timeout: 2)
    )

    app.terminate()
    app.launchArguments.append("--notebook-reopen-fixture")
    launchPortraitFixture(app)
    let reopenedPaper = app.otherElements["paper-input"]
    XCTAssertTrue(reopenedPaper.waitForExistence(timeout: 5))
    XCTAssertEqual(reopenedPaper.value as? String, "81 действий пера")
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "one-pen-contact-after-cold-reopen"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testEraserKeepsDensePaperResponsive() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)

    let controls = app.buttons["pen-controls-toggle"]
    XCTAssertTrue(controls.waitForExistence(timeout: 5))

    let eraser = app.buttons["drawing-tool-eraser"]
    XCTAssertTrue(eraser.waitForExistence(timeout: 2))
    eraser.tap()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 2))
    guard let initialValue = paper.value as? String else {
      XCTFail("Лист должен сообщать число штрихов")
      return
    }
    XCTAssertEqual(initialValue, "80 действий пера")
    let start = paper.coordinate(
      withNormalizedOffset: CGVector(dx: 0.12, dy: 0.48)
    )
    let end = paper.coordinate(
      withNormalizedOffset: CGVector(dx: 0.88, dy: 0.56)
    )
    let dragStarted = ContinuousClock.now
    start.press(
      forDuration: 0.05,
      thenDragTo: end,
      withVelocity: .slow,
      thenHoldForDuration: 0
    )
    XCTAssertLessThan(
      ContinuousClock.now - dragStarted,
      .seconds(6),
      "Ластик не должен ставить вычисление всего рисунка в очередь UI"
    )

    let secondStarted = ContinuousClock.now
    paper.coordinate(
      withNormalizedOffset: CGVector(dx: 0.12, dy: 0.68)
    ).press(
      forDuration: 0.04,
      thenDragTo: paper.coordinate(
        withNormalizedOffset: CGVector(dx: 0.88, dy: 0.76)
      ),
      withVelocity: .fast,
      thenHoldForDuration: 0
    )
    XCTAssertLessThan(
      ContinuousClock.now - secondStarted,
      .seconds(4),
      "Второй жест ластика должен начаться сразу после подъёма Pencil"
    )

    let responseStarted = ContinuousClock.now
    controls.tap()
    let controlsClosed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Ручка"),
      object: controls
    )
    wait(for: [controlsClosed], timeout: 2)
    XCTAssertLessThan(ContinuousClock.now - responseStarted, .seconds(2))

    let bothErasersLanded = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == '82 действий пера'"),
      object: paper
    )
    wait(for: [bothErasersLanded], timeout: 2)
  }

  func testErasureIsCommittedBeforeLeavingAndColdReopeningTheNotebook() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-simulator-mixed-input",
    ]
    launchPortraitFixture(app)

    let controls = app.buttons["pen-controls-toggle"]
    XCTAssertTrue(controls.waitForExistence(timeout: 5))
    let eraser = app.buttons["drawing-tool-eraser"]
    XCTAssertTrue(eraser.waitForExistence(timeout: 2))
    eraser.tap()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 2))
    let originalValue = paper.value as? String
    XCTAssertEqual(originalValue, "80 действий пера")
    paper.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.48))
      .press(
        forDuration: 0.04,
        thenDragTo: paper.coordinate(
          withNormalizedOffset: CGVector(dx: 0.88, dy: 0.56)
        ),
        withVelocity: .fast,
        thenHoldForDuration: 0
      )
    let erased = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != %@", originalValue ?? ""),
      object: paper
    )
    await fulfillment(of: [erased], timeout: 2)
    try await Task.sleep(for: .milliseconds(700))
    let beforeClosing = app.screenshot()
    XCTAssertGreaterThan(
      visibleInkPixelShare(
        in: beforeClosing,
        normalizedRect: CGRect(x: 0.12, y: 0.16, width: 0.76, height: 0.68)
      ),
      0.005,
      "Суд повторного входа должен начинаться с видимых устойчивых чернил"
    )

    // XCTest direct contacts represent Pencil in this launch. Close through
    // the real navigation control, then use a cold finger-only launch rather
    // than pretending the same direct contact is also a physical finger.
    app.buttons["leave-nested-board"].tap()
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))
    app.terminate()
    app.launchArguments.removeAll { $0 == "--notebook-simulator-mixed-input" }
    app.launchArguments.append("--notebook-reopen-fixture")
    launchPortraitFixture(app)
    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 2))
    notebook.doubleTap()

    let reopened = app.otherElements["paper-input"]
    XCTAssertTrue(reopened.waitForExistence(timeout: 5))
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertNotEqual(
      reopened.value as? String,
      originalValue,
      "Закрытие должно дождаться сериализации ластика"
    )
    let afterReopening = app.screenshot()
    XCTAssertLessThan(
      changedPixelShare(
        from: beforeClosing,
        to: afterReopening,
        normalizedRect: CGRect(x: 0.12, y: 0.16, width: 0.76, height: 0.68)
      ),
      0.01,
      "Повторный вход должен показать те же завершённые пиксели листа"
    )
  }
}
