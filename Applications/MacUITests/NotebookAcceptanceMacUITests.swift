import AppKit
import XCTest

/// Opens the ordinary pairing window and uses its real controls. No trust
/// record, invitation or confirmation is injected by the test route.
@MainActor final class NotebookAcceptanceMacUITests: XCTestCase {
  private var application: XCUIApplication!

  override func setUpWithError() throws {
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MAC_APPLICATION"])
    // Several isolated runs may share a bundle identifier. The test belongs
    // to its attested application path, never an arbitrary running helper.
    application = XCUIApplication(url: URL(fileURLWithPath: path))
  }

  private func pairingWindow() throws -> XCUIElement {
    continueAfterFailure = false
    let manifest = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MANIFEST"])
    if application.state == .notRunning {
      application.launchEnvironment["NOTEBOOK_ACCEPTANCE_MANIFEST"] = manifest
      application.launch()
    } else { application.activate() }
    let window = application.windows["notebook.pairing.window"]
    if !window.exists {
      let item = application.menuBars.statusItems.firstMatch
      XCTAssertTrue(item.waitForExistence(timeout: 15), application.debugDescription)
      item.click()
      let pairing = application.menuItems["notebook.pairing.open"]
      XCTAssertTrue(pairing.waitForExistence(timeout: 5), application.debugDescription)
      pairing.click()
    }
    XCTAssertTrue(window.waitForExistence(timeout: 5), application.debugDescription)
    return window
  }

  func testCreateInvitationThroughMenu() throws {
    let window = try pairingWindow()
    let copy = window.buttons["notebook.pairing.copy-invitation"]
    XCTAssertTrue(copy.waitForExistence(timeout: 5))
    let previousClipboard = NSPasteboard.general.changeCount
    copy.click()
    let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      NSPasteboard.general.changeCount > previousClipboard && copy.isEnabled
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 10), .completed,
      "The ordinary copy action must finish before reading its new invitation")
    let invitation = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
    XCTAssertTrue(invitation.hasPrefix("notebook"))
    let output = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_INVITATION_FILE"])
    try Data(invitation.utf8).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output)
    let proof = XCTAttachment(screenshot: application.screenshot())
    proof.name = "mac-invitation-created-by-user-control"; proof.lifetime = .keepAlways; add(proof)
  }

  func testConfirmOnlyTheDisplayedAcceptancePeer() throws {
    let window = try pairingWindow()
    let peer = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_PEER_ID"])
    let workspace = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_WORKSPACE_ID"])
    let peerID = window.staticTexts["notebook.pairing.peer-id"]
    XCTAssertTrue(peerID.waitForExistence(timeout: 10))
    XCTAssertEqual(peerID.label, "Устройство: " + peer.lowercased())
    XCTAssertEqual(window.staticTexts["notebook.pairing.workspace-id"].label, "Пространство: " + workspace.lowercased())
    let confirm = window.buttons["notebook.pairing.confirm"]
    XCTAssertTrue(confirm.exists)
    let before = XCTAttachment(screenshot: application.screenshot())
    before.name = "mac-real-peer-before-confirmation"; before.lifetime = .keepAlways; add(before)
    confirm.click()
    let paired = window.descendants(matching: .any).matching(identifier: "notebook.pairing.paired").firstMatch
    XCTAssertTrue(paired.waitForExistence(timeout: 20), "A click is not saved trust or an admitted connection")
    let after = XCTAttachment(screenshot: application.screenshot())
    after.name = "mac-paired-after-saved-confirmation"; after.lifetime = .keepAlways; add(after)
  }
}
