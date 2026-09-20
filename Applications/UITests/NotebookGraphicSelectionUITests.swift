import XCTest

@MainActor final class NotebookGraphicSelectionUITests: XCTestCase {
  func testSelectMoveAlignDuplicateAndRestoreOnPage() { scenario(onPage:true) }
  func testSelectMoveAlignDuplicateAndRestoreOnBoard() { scenario(onPage:false) }

  func testMoveWholeWithPassiveMembersAndRestore() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app=XCUIApplication()
    app.launchArguments=["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture","--notebook-native-whole"]
    app.launch()
    let node=app.images["Узел +"]
    XCTAssertTrue(node.waitForExistence(timeout:15))
    let neighbour=app.webViews.containing(.button,identifier:"Graphic scene counter").firstMatch
    XCTAssertTrue(neighbour.waitForExistence(timeout:10))
    neighbour.buttons["Graphic scene counter"].tap()
    XCTAssertTrue(neighbour.staticTexts["Count 1"].waitForExistence(timeout:3))
    let runtime=neighbour.staticTexts.matching(NSPredicate(format:"label BEGINSWITH 'Runtime '")).firstMatch.label
    node.tap();app.buttons["element-actions-menu"].tap();app.buttons["Выбрать группу"].tap()
    let handle=app.descendants(matching:.any)["move-element-group"]
    XCTAssertTrue(handle.waitForExistence(timeout:5))
    let before=node.frame,from=handle.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
    proof(app,"whole-before")
    from.press(forDuration:0.01,thenDragTo:from.withOffset(.init(dx:70,dy:45)),withVelocity:.slow,thenHoldForDuration:0.3)
    let moved=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in node.frame.midX>before.midX+50 && node.frame.midY>before.midY+30 },object:nil)
    XCTAssertEqual(XCTWaiter.wait(for:[moved],timeout:8),.completed)
    let after=node.frame
    XCTAssertEqual(after.minX-before.minX,70,accuracy:3);XCTAssertEqual(after.minY-before.minY,45,accuracy:3)
    XCTAssertEqual(neighbour.staticTexts.matching(NSPredicate(format:"label BEGINSWITH 'Runtime '")).firstMatch.label,runtime)
    XCTAssertTrue(neighbour.staticTexts["Count 1"].exists)
    proof(app,"whole-moved")
    app.terminate();app.launchArguments.append("--notebook-reopen-fixture");app.launch()
    XCTAssertTrue(node.waitForExistence(timeout:15))
    XCTAssertEqual(node.frame.minX,after.minX,accuracy:3);XCTAssertEqual(node.frame.minY,after.minY,accuracy:3)
    proof(app,"whole-reopened")
  }

  private func scenario(onPage: Bool) {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture","--notebook-native-connector"]
      + (onPage ? ["--notebook-native-graphic-page"] : [])
    app.launch()
    let a = app.images["Узел +"], b = app.images["Узел −"], link = app.images["1:2"]
    XCTAssertTrue(a.waitForExistence(timeout:12)); XCTAssertTrue(b.exists); XCTAssertTrue(link.exists)
    let neighbour = app.webViews.containing(.button,identifier:"Graphic scene counter").firstMatch
    neighbour.buttons["Graphic scene counter"].tap()
    XCTAssertTrue(neighbour.staticTexts["Count 1"].waitForExistence(timeout:3))
    let runtime = neighbour.staticTexts.matching(NSPredicate(format:"label BEGINSWITH 'Runtime '")).firstMatch.label
    a.tap(); XCTAssertTrue(app.buttons["element-actions-menu"].waitForExistence(timeout:3))
    app.buttons["element-actions-menu"].tap(); app.buttons["Выбрать несколько"].tap()
    b.tap()
    XCTAssertTrue(app.buttons["finish-graphic-selection"].waitForExistence(timeout:3))
    XCTAssertEqual(app.buttons["finish-graphic-selection"].label,"Завершить выбор: 2")
    XCTAssertEqual(app.otherElements.matching(identifier:"notebook-context-menu").count,1)
    link.tap()
    let three = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.buttons["finish-graphic-selection"].label == "Завершить выбор: 3" },object:nil)
    XCTAssertEqual(XCTWaiter.wait(for:[three],timeout:3),.completed)
    app.buttons["finish-graphic-selection"].tap()
    let fa = a.frame, fb = b.frame, fl = link.frame
    let from = a.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
    from.press(forDuration:0.01,thenDragTo:from.withOffset(.init(dx:40,dy:35)),withVelocity:.slow,thenHoldForDuration:0)
    let moved = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in a.frame.midX > fa.midX+25 && b.frame.midX > fb.midX+25 },object:nil)
    XCTAssertEqual(XCTWaiter.wait(for:[moved],timeout:5),.completed)
    XCTAssertEqual(a.frame.minX-fa.minX,b.frame.minX-fb.minX,accuracy:2)
    XCTAssertEqual(link.frame.minX-fl.minX,a.frame.minX-fa.minX,accuracy:2)
    XCTAssertEqual(link.frame.minY-fl.minY,a.frame.minY-fa.minY,accuracy:2)
    proof(app,"selection-moved-\(onPage)")
    app.buttons["element-actions-menu"].tap(); app.buttons["Выровнять"].tap(); app.buttons["По левому краю"].tap()
    let aligned = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in abs(a.frame.minX-b.frame.minX) < 2 },object:nil)
    XCTAssertEqual(XCTWaiter.wait(for:[aligned],timeout:5),.completed)
    XCTAssertEqual(neighbour.staticTexts.matching(NSPredicate(format:"label BEGINSWITH 'Runtime '")).firstMatch.label,runtime)
    XCTAssertTrue(neighbour.staticTexts["Count 1"].exists)
    app.buttons["element-actions-menu"].tap(); app.buttons["Дублировать"].tap()
    let copied = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.images.matching(identifier:"Узел +").count == 2 && app.images.matching(identifier:"1:2").count == 2 },object:nil)
    XCTAssertEqual(XCTWaiter.wait(for:[copied],timeout:6),.completed)
    proof(app,"selection-copied-\(onPage)")
    app.buttons["delete-graphic-selection"].tap()
    let deleted = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.images.matching(identifier:"Узел +").count == 1 && app.images.matching(identifier:"1:2").count == 1 },object:nil)
    XCTAssertEqual(XCTWaiter.wait(for:[deleted],timeout:6),.completed)
    app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); app.launch()
    XCTAssertTrue(app.images["Узел +"].waitForExistence(timeout:10)); XCTAssertTrue(app.images["Узел −"].exists); XCTAssertTrue(app.images["1:2"].exists)
    XCTAssertEqual(app.images.matching(identifier:"Узел +").count,1)
    // An internal copied binding follows the copied node after cold restore.
    let copy = app.images["Узел −"], before = app.images["1:2"].frame
    let p = copy.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
    p.press(forDuration:0.01,thenDragTo:p.withOffset(.init(dx:45,dy:30)),withVelocity:.slow,thenHoldForDuration:0)
    let bound = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.images["1:2"].frame != before },object:nil)
    XCTAssertEqual(XCTWaiter.wait(for:[bound],timeout:5),.completed)
    proof(app,"selection-restored-binding-\(onPage)")
  }

  private func proof(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot:app.screenshot()); attachment.name = name
    attachment.lifetime = .keepAlways; add(attachment)
  }
}
