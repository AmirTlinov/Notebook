import UIKit
import UniformTypeIdentifiers
import XCTest

@MainActor final class NotebookTldrawPasteUITests: XCTestCase {
  func testSelectedTldrawObjectsStayEditableOnPage() { paste(onPage:true) }
  func testSelectedTldrawObjectsStayEditableOnBoard() { paste(onPage:false) }

  private func paste(onPage:Bool) {
    continueAfterFailure=false
    XCUIDevice.shared.orientation = .portrait
    let app=XCUIApplication()
    app.launchArguments=["--notebook-drawing-responsiveness-fixture","--notebook-native-graphics-fixture"]
      + (onPage ? ["--notebook-native-graphic-page"] : [])
    app.launchEnvironment["NOTEBOOK_CLIPBOARD_HTML"]=Self.html
    app.launch()
    let paste=app.buttons["clipboard-paste"]
    XCTAssertFalse(paste.exists,"Paste belongs to the canvas context")
    openNotebookCanvasMenu(in:app)
    XCTAssertTrue(paste.waitForExistence(timeout:3))
    XCTAssertFalse(app.staticTexts["Из tldraw"].exists)
    let menu=XCTAttachment(screenshot:app.screenshot());menu.name="notebook-actions-menu-\(onPage)";menu.lifetime = .keepAlways;add(menu)
    XCTAssertTrue(paste.isEnabled)
    paste.tap()
    let omitted=app.buttons["tldraw-item-shape:ignored"], insert=app.buttons["paste-insert"]
    XCTAssertTrue(omitted.waitForExistence(timeout:8))
    XCTAssertFalse(insert.isEnabled,"Unsupported selected images never silently disappear")
    omitted.tap()
    let ready=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in insert.isEnabled },object:nil)
    XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:5),.completed)
    let before=XCTAttachment(screenshot:app.screenshot());before.name="tldraw-selected-preview-\(onPage)";before.lifetime = .keepAlways;add(before)
    insert.tap()
    XCTAssertTrue(insert.waitForNonExistence(timeout:8))
    XCTAssertTrue(paste.waitForNonExistence(timeout:5),"Completed paste returns to the canvas, not a stranded popover")
    let a=app.images["TL A"],b=app.images["TL B"],link=app.images["TL link"]
    XCTAssertTrue(a.waitForExistence(timeout:8));XCTAssertTrue(b.exists);XCTAssertTrue(link.exists)
    let original=b.frame, arrow=link.frame
    b.tap()
    XCTAssertTrue(app.otherElements["resize-agent-element-topLeading"].waitForExistence(timeout:3))
    let from=b.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
    from.press(forDuration:0.01,thenDragTo:from.withOffset(.init(dx:25,dy:80)),withVelocity:.slow,thenHoldForDuration:0)
    let moved=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in b.frame.midY > original.midY+60 },object:nil)
    XCTAssertEqual(XCTWaiter.wait(for:[moved],timeout:4),.completed,"Pasted objects use normal manipulation, not a flat image")
    XCTAssertNotEqual(link.frame,arrow,"Internal binding follows the moved node")
    let proof=XCTAttachment(screenshot:app.screenshot());proof.name="tldraw-editable-bound-objects-\(onPage)";proof.lifetime = .keepAlways;add(proof)
    notebookContextAction("Удалить элемент",on:b,in:app)
    XCTAssertTrue(b.waitForNonExistence(timeout:5))
    XCTAssertTrue(a.exists,"Deleting one imported object must leave its neighbour")
    app.terminate()
    app.launchArguments.append("--notebook-reopen-fixture")
    app.launch()
    XCTAssertTrue(a.waitForExistence(timeout:8));XCTAssertFalse(b.exists)
  }
}

private extension NotebookTldrawPasteUITests {
  static let html = #"<div data-tldraw>{"type":"application/tldraw","kind":"content","version":3,"data":{"assets":[],"otherCompressed":"N4IgzgxgFgpgtgQxALlJWiBqMBOYCWA9gHYoBMANODAI4CuMxEMYKoEhcAdAC4A2AExwIA7lzBQEABxhcA5jEIoAjJRAdu/IaPGSZXBDhyERKABwBfC1QnSWKANqh8AlOD0xkSKjwCeMtwUlKilDRh4ASVdkEFCFZGNCHhAqfGIBGAAPNwRvEGzkAAYqXxRikGMeBB4iUiKQ4ylWVHVCPkIcNwAjPgQIAGsUkAAzfD4+NzA2lyGBBAlJ6dcbfAAvGDc4IdNkZULyqHNyoLceHHwEYjk+Dapz6AAVLOSWvwCYgUIIIY5iHnDHKA3hsYqFhHJhFJDlRqmdmqABPhOjEEHQeEprK0/gDkE4QMDTs8hv9Mi8QA8ADIAAgAgiALABdRlWazOaLuOzILrE/wgkAnEJhP5RNxxTyJZKpdJZHLcqgFMgANnKpXqFSS1VqZQahCabFa7WRIB6fUGVFG40WfBmVDmCxiU2ty3Aaz5WyoOz2ByOVBOMRg43wTVuFXwjyJr15bk+3yov3+f0B+KjoMMCAh0mhIFheH1iKNqPR9LjJATLzxBJiJMl+Ij5OpACF6UymVYKGzJh5kLHk+9s0YTEMweERan4hKhmkMgVsz2Cl6SigACzlSqakja2KNeEGjrdPgMWbzQ4OpZDAjrTbnqo4F6gAoqsqYxjRe8qZWLoqYwzGESwBACAAoukOQDqYdxhlATykvqlYgDGPyljiFYprEaYZlCQw5ju+Y5GiGIltiia4kCqHVsSdaUlS1rEIMzKtqyIAzA6Xb4HIxAdDAzpwfgiAKEOQqROyYoJIQSSTtKM4IGxHE4FxQwFAArPsn6rhqNQbmqUjbvqnoqSAJ4LtmYBgDAQk5CZZnINkVgMlQXRTmkcjNHizHGo5VxeDyfY/oO5rGHAo4cjI3bEoQQW2CFeTabqO7/DgcBpAgEwOjeNayYg1rrAINJMFAe4tPOqlcIpmL4GAgGZH0LxnAwqRgAACnJEDlSCtUwG2HYxA56ROVy3l8r54EjAFEVdj26JjZycpbrFsG4IlxDJW4L5DBlyWujleUFW+aqqoUJVlRVVUQDVOB1UxjXNa1KDtbZFhAA="}}</div>"#
}
