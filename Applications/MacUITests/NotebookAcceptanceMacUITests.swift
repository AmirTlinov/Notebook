import AppKit
import XCTest

/// Opens the ordinary pairing window and uses its real controls. No trust
/// record, invitation or confirmation is injected by the test route.
@MainActor final class NotebookAcceptanceMacUITests: XCTestCase {
  private let application = XCUIApplication(bundleIdentifier: "com.amirtlinov.notebook.mac.acceptance")

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
    copy.click()
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
    XCTAssertEqual(window.staticTexts["notebook.pairing.workspace-id"].label, "Архив: " + workspace.lowercased())
    let confirm = window.buttons["notebook.pairing.confirm"]
    XCTAssertTrue(confirm.exists)
    let before = XCTAttachment(screenshot: application.screenshot())
    before.name = "mac-real-peer-before-confirmation"; before.lifetime = .keepAlways; add(before)
    confirm.click()
  }
}
