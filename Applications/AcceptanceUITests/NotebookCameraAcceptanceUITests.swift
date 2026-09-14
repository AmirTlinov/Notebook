#if NOTEBOOK_CAMERA_ACCEPTANCE
import UIKit
import XCTest

/// Compiled only by Tests/NotebookCameraAcceptance/run.py into a separate
/// Simulator bundle. The same file drives baseline and current app binaries.
@MainActor final class NotebookCameraAcceptanceUITests: XCTestCase {
  private let app = XCUIApplication(bundleIdentifier: "com.amirtlinov.notebook.cameraaudit")

  func testCameraKeepsVectorAndLiveControlAttachedToNativeInk() throws {
    continueAfterFailure = false
    for key in ["NOTEBOOK_CAMERA_AUDIT_RUN", "NOTEBOOK_CAMERA_AUDIT_VARIANT"] {
      app.launchEnvironment[key] = try XCTUnwrap(ProcessInfo.processInfo.environment[key])
    }
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    let ink = app.otherElements["spatial-ink"]
    XCTAssertTrue(ink.waitForExistence(timeout: 30), app.debugDescription)
    // AX availability is an observation, not a condition for measuring visible
    // camera pixels. The old release may need its ordinary double-tap focus.
    // First-touch usability has a separate unprimed acceptance scenario.
    let contact = ink.coordinate(withNormalizedOffset: .init(dx: 517.0 / 834, dy: 592.0 / 1194))
    capture("camera-before-control")
    contact.tap()
    let control = app.webViews.buttons["Camera pulse"]
    let firstTapAccessible = control.waitForExistence(timeout: 2)
    capture(firstTapAccessible ? "control-after-first-tap" : "control-AX-unavailable-after-first-tap")
    if !firstTapAccessible { contact.doubleTap() }
    let afterActivationAccessible = control.waitForExistence(timeout: 2)
    contact.tap()
    let activation = XCTAttachment(string: "firstTapAX=\(firstTapAccessible); afterOrdinaryActivationAX=\(afterActivationAccessible)\n\(app.debugDescription)")
    activation.name = "camera-control-activation"; activation.lifetime = .keepAlways; add(activation)
    capture("camera-start")
    for index in 0..<10 {
      XCTContext.runActivity(named: "camera-gesture-\(index)") { _ in
        let origin = ink.coordinate(withNormalizedOffset: .init(dx: 0.78, dy: 0.34))
        let end = origin.withOffset(.init(dx: -100, dy: 55))
        // Cross the existing 8pt/350ms hold boundary before moving slowly.
        // 12pt/s is an area hold, not a camera pan: its long duration provides
        // no motion samples. 40pt/s keeps the same native gesture contract.
        // Only captured intervals inside accepted camera movement count.
        XCTContext.runActivity(named: "slow-continuous-pan-\(index)") { _ in
          origin.press(forDuration: 0.01, thenDragTo: end,
            withVelocity: .init(rawValue: 40), thenHoldForDuration: 0)
          end.press(forDuration: 0.01, thenDragTo: origin,
            withVelocity: .init(rawValue: 40), thenHoldForDuration: 0)
        }
        XCTContext.runActivity(named: "fast-pan-\(index)") { _ in
          origin.press(forDuration: 0.01, thenDragTo: end,
            withVelocity: .fast, thenHoldForDuration: 0)
          end.press(forDuration: 0.01, thenDragTo: origin,
            withVelocity: .fast, thenHoldForDuration: 0)
        }
        // XCTest's requested scale is best effort. Its opening gesture begins
        // with a measured 6.7pt contact gap on this Simulator: requesting 1.12
        // yields a real 2.319x distance change. Both app revisions receive this
        // same bounded close/open pair; the saved contacts and every pixel
        // checkpoint independently reject an out-of-frame or unmeasured run.
        ink.pinch(withScale: 0.43, velocity: -0.7)
        ink.pinch(withScale: 1.12, velocity: 0.7)
        capture("camera-settled-\(index)")
      }
    }
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
    capture("camera-finish")
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }
}
#endif
