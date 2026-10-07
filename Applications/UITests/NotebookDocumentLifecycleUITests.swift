import XCTest

/// Real input and a fresh process read back the same durable program state.
/// XCTest's remote AX/gesture time is not an application latency measurement.
@MainActor final class NotebookDocumentLifecycleUITests: XCTestCase {
  func testColdCoverOpeningFitsCustomPaperAndPreservesReadingZoom() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture",
      "--notebook-document-fit-fixture"]
    app.launch()
    defer { XCUIDevice.shared.orientation = .portrait }
    rotateNotebook(to: .portrait, in: app)
    let surface = app.otherElements["page-turn-surface"]
    let document = app.descendants(matching: .any)
      .matching(identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000006").firstMatch

    func capture(_ name: String) {
      let screen = XCUIScreen.main.screenshot()
      let geometry = XCTAttachment(string: "application=\(app.frame), window=\(app.windows.firstMatch.frame), "
        + "paper=\(surface.frame), deviceOrientation=\(XCUIDevice.shared.orientation.rawValue), "
        + "imageSize=\(screen.image.size), imageScale=\(screen.image.scale), "
        + "imageOrientation=\(screen.image.imageOrientation.rawValue)")
      geometry.name = "\(name)-geometry"; geometry.lifetime = .keepAlways; add(geometry)
      let image = XCTAttachment(screenshot: screen)
      image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func openCover() {
      XCTAssertTrue(surface.waitForNonExistence(timeout: 10), "The source begins behind a closed cover")
      XCTAssertTrue(document.waitForExistence(timeout: 10))
      let visible = document.frame.intersection(app.windows.firstMatch.frame)
      XCTAssertGreaterThan(visible.width, 80); XCTAssertGreaterThan(visible.height, 80)
      app.coordinate(withNormalizedOffset: .zero).withOffset(.init(
        dx: visible.midX - app.frame.minX, dy: visible.midY - app.frame.minY)).doubleTap()
      XCTAssertTrue(surface.waitForExistence(timeout: 15))
    }
    func assertFit(_ name: String) {
      let tolerance: CGFloat = 2
      // AX can expose the page before native camera settlement completes.
      // This bounded state wait does not measure opening latency.
      let fitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        guard surface.exists else { return false }
        let paper = surface.frame, window = app.windows.firstMatch.frame
        return paper.width > 0 && paper.height > 0
          && abs(paper.width / paper.height - 1.5) <= 0.005
          && paper.minX >= window.minX - tolerance && paper.minY >= window.minY - tolerance
          && paper.maxX <= window.maxX + tolerance && paper.maxY <= window.maxY + tolerance
          && (abs(paper.width - window.width) <= tolerance || abs(paper.height - window.height) <= tolerance)
          && abs(paper.midX - window.midX) <= tolerance && abs(paper.midY - window.midY) <= tolerance
      }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [fitted], timeout: 5), .completed)
      // This is IPadPageTurnController's physical paper rectangle, inside the
      // item pose. The authored 3:2 ratio also detects clipped or stretched AX bounds.
      let paper = surface.frame, window = app.windows.firstMatch.frame
      XCTAssertEqual(paper.width / paper.height, 1.5, accuracy: 0.005)
      XCTAssertGreaterThanOrEqual(paper.minX, window.minX - tolerance)
      XCTAssertGreaterThanOrEqual(paper.minY, window.minY - tolerance)
      XCTAssertLessThanOrEqual(paper.maxX, window.maxX + tolerance)
      XCTAssertLessThanOrEqual(paper.maxY, window.maxY + tolerance)
      XCTAssertTrue(abs(paper.width - window.width) <= tolerance
        || abs(paper.height - window.height) <= tolerance, "Fitted paper must reach one viewport dimension")
      XCTAssertEqual(paper.midX, window.midX, accuracy: tolerance)
      XCTAssertEqual(paper.midY, window.midY, accuracy: tolerance, "Remaining paper margins are centered")
      capture(name)
    }

    openCover()
    assertFit("custom-paper-first-cold-cover-opening")
    rotateNotebook(to: .landscapeLeft, in: app)
    assertFit("custom-paper-landscape")
    rotateNotebook(to: .portrait, in: app)
    assertFit("custom-paper-portrait-return")
    for cycle in 1...3 {
      notebookBack(in: app)
      openCover()
      assertFit("custom-paper-immediate-reopen-\(cycle)")
    }

    // XCTest includes recognition movement in its synthesized pinch. Read the
    // accepted paper pose from its unclipped AX frame before testing restoration.
    let fittedPaper = surface.frame
    surface.pinch(withScale: 1.35, velocity: 0.5)
    let enlarged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      surface.exists && surface.frame.height > fittedPaper.height * 1.1
    }, object: nil)
    let enlargement = XCTWaiter.wait(for: [enlarged], timeout: 5)
    let zoomedPaper = surface.frame
    capture("custom-paper-zoomed")
    XCTAssertEqual(enlargement, .completed)
    XCTAssertEqual(zoomedPaper.width / zoomedPaper.height, 1.5, accuracy: 0.005,
      "The enlarged AX rectangle must retain the full paper geometry")
    notebookBack(in: app)
    openCover()
    let restoredZoom = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard surface.exists else { return false }
      let paper = surface.frame
      return abs(paper.width - zoomedPaper.width) <= 2 && abs(paper.height - zoomedPaper.height) <= 2
        && abs(paper.midX - zoomedPaper.midX) <= 2 && abs(paper.midY - zoomedPaper.midY) <= 2
    }, object: nil)
    let restoration = XCTWaiter.wait(for: [restoredZoom], timeout: 5)
    capture("custom-paper-reopened-at-reading-zoom")
    XCTAssertEqual(restoration, .completed)
    let restoredPaper = surface.frame
    XCTAssertEqual(restoredPaper.width, zoomedPaper.width, accuracy: 2)
    XCTAssertEqual(restoredPaper.height, zoomedPaper.height, accuracy: 2, "The reading zoom survives closing and reopening")
    XCTAssertEqual(restoredPaper.midX, zoomedPaper.midX, accuracy: 2)
    XCTAssertEqual(restoredPaper.midY, zoomedPaper.midY, accuracy: 2, "The reading position survives closing and reopening")
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "persistence-failure").firstMatch.exists)
  }

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
