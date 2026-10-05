import XCTest

/// Real input and a fresh process read back the same durable program state.
/// XCTest's remote AX/gesture time is not an application latency measurement.
@MainActor final class NotebookDocumentLifecycleUITests: XCTestCase {
  func testFirstActionSurvivesImmediatePageChangeCloseAndColdReopen() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture"]
    app.launch()
    rotateNotebook(to: .portrait, in: app)
    let surface = app.otherElements["page-turn-surface"]
    let slider = app.webViews.sliders.firstMatch
    XCTAssertTrue(slider.waitForExistence(timeout: 20))
    XCTAssertTrue(slider.wait(for: \.isHittable, toEqual: true, timeout: 10))
    let initial = try XCTUnwrap(slider.value as? String)
    slider.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.5)).press(forDuration: 0.05,
      thenDragTo: slider.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.5)),
      withVelocity: .slow, thenHoldForDuration: 0)
    let accepted = try XCTUnwrap(slider.value as? String)
    XCTAssertNotEqual(accepted, initial, "The first contact must change the visible control without an activation tap")
    // No sleep or persistence wait before leaving the page that accepted input.
    app.buttons["next-page"].tap()
    let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"), object: surface)
    XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 10), .completed)
    app.buttons["previous-page"].tap()
    XCTAssertTrue(slider.waitForExistence(timeout: 10))
    XCTAssertEqual(slider.value as? String, accepted)

    notebookBack(in: app)
    XCTAssertTrue(surface.waitForNonExistence(timeout: 10))
    let cover = app.descendants(matching: .any)
      .matching(identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000006").firstMatch
    XCTAssertTrue(cover.wait(for: \.isHittable, toEqual: true, timeout: 10))
    cover.doubleTap()
    XCTAssertTrue(slider.waitForExistence(timeout: 10))
    XCTAssertEqual(slider.value as? String, accepted)
    let shown = XCTAttachment(screenshot: app.screenshot())
    shown.name = "First document action after page change and close"; shown.lifetime = .keepAlways; add(shown)

    // A new app process must reconstruct the result from the same fixture store.
    app.terminate()
    app.launchArguments.append("--notebook-reopen-fixture")
    app.launch()
    XCTAssertTrue(slider.waitForExistence(timeout: 20))
    XCTAssertTrue(slider.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertEqual(slider.value as? String, accepted)
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "persistence-failure").firstMatch.exists)
    let reopened = XCTAttachment(screenshot: app.screenshot())
    reopened.name = "First document action after cold process reopen"; reopened.lifetime = .keepAlways; add(reopened)
  }
}
