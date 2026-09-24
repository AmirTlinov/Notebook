import XCTest

@MainActor final class NotebookCanvasMenuUITests:XCTestCase {
  func testHoldUpCopiesCutsAndPastesTheCapturedElementWithoutMovingIt() {
    continueAfterFailure=false
    let app=XCUIApplication()
    app.launchArguments=["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture","--notebook-native-graphic-page"]
    app.launch();XCUIDevice.shared.orientation = .portrait
    let node=app.images["Узел +"],paper=app.otherElements["paper-input"]
    XCTAssertTrue(node.waitForExistence(timeout:12));let frame=node.frame,paperFrame=paper.frame
    openNotebookSelectionMenu(on:node,in:app)
    XCTAssertTrue(notebookMenuItem("Вырезать",in:app).isEnabled);XCTAssertTrue(notebookMenuItem("Копировать",in:app).isEnabled)
    XCTAssertEqual(node.frame,frame,"A quiet hold creates no move")
    let menu=XCTAttachment(screenshot:app.screenshot());menu.name="full-captured-element-menu";menu.lifetime = .keepAlways;add(menu)
    notebookMenuItem("Копировать",in:app).tap()
    openNotebookSelectionMenu(on:node,in:app);notebookMenuItem("Вырезать",in:app).tap()
    XCTAssertTrue(node.waitForNonExistence(timeout:5))
    openNotebookCanvasMenu(in:app);app.buttons["clipboard-paste"].tap()
    XCTAssertTrue(node.waitForExistence(timeout:8))
    XCTAssertEqual(paper.frame,paperFrame)
    app.terminate();app.launchArguments.append("--notebook-reopen-fixture");app.launch()
    XCTAssertTrue(node.waitForExistence(timeout:12))
    XCTAssertEqual(app.images.matching(identifier:"Узел +").count,1)
  }
}
