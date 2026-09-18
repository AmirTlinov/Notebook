import XCTest

@MainActor final class NotebookAgentFeedbackUITests: XCTestCase {
  func testAgentMaterialLeavesProgramTapsAndObjectDraggingWithTheHuman() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture",
      "--notebook-agent-feedback-fixture","--notebook-simulator-finger-gestures"]
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    let node = app.images.matching(NSPredicate(format:"label BEGINSWITH 'Agent '")).firstMatch
    let neighbour = app.webViews.containing(.button,identifier:"Graphic scene counter").firstMatch
    XCTAssertTrue(node.waitForExistence(timeout:15)); XCTAssertTrue(neighbour.waitForExistence(timeout:10))
    let runtime = neighbour.staticTexts.matching(NSPredicate(format:"label BEGINSWITH 'Runtime '")).firstMatch.label
    let proof = XCTAttachment(screenshot:app.screenshot()); proof.name="agent-feedback-during-real-result"; proof.lifetime = .keepAlways; add(proof)
    neighbour.buttons["Graphic scene counter"].tap()
    XCTAssertEqual(neighbour.staticTexts.matching(NSPredicate(format:"label BEGINSWITH 'Runtime '")).firstMatch.label,runtime)
    let draft = neighbour.textFields["Graphic scene draft"]
    draft.tap(); draft.typeText(" live")
    XCTAssertTrue((draft.value as? String)?.contains("live") == true,"Feedback cannot intercept program input or replace its DOM")
    let before = node.frame, programFrame = neighbour.frame
    let start = node.coordinate(withNormalizedOffset:.init(dx:0.98,dy:0.5))
    start.press(forDuration:0.01,thenDragTo:start.withOffset(.init(dx:40,dy:30)),withVelocity:.slow,thenHoldForDuration:0)
    XCTAssertEqual(node.frame.midX-before.midX,40,accuracy:6)
    XCTAssertEqual(node.frame.midY-before.midY,30,accuracy:6)
    XCTAssertEqual(neighbour.frame,programFrame,"The effect does not turn an object drag into camera movement")
    XCTAssertEqual(neighbour.staticTexts.matching(NSPredicate(format:"label BEGINSWITH 'Runtime '")).firstMatch.label,runtime)
    app.typeText("!")
    XCTAssertTrue((draft.value as? String)?.contains("live!") == true,"The same program keeps its first responder through the drag")
    let after = XCTAttachment(screenshot:app.screenshot()); after.name="agent-feedback-human-drag"; after.lifetime = .keepAlways; add(after)
  }
}
