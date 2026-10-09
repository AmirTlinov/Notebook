import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentPaperCoordinatorTests: XCTestCase {
  func testPaperLinksSourceAndAccessibilityInstallWithoutAnyWebAdmission() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1, reservedInteractiveSlots: 0)
    let blocker = try await resources.acquireWebSurface(priority: .input)
    defer { blocker.release() }
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source:
      "Visible native article. \\hyperlink{target}{Open target}\\newpage\\hypertarget{target}{}Target page.")])
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    defer { fixture.close() }
    try await ready(fixture)
    let paper = try XCTUnwrap(fixture.paper(in: 0))
    XCTAssertEqual(paper.raster?.page.artifact.document, document)
    XCTAssertFalse(views(fixture.hosts[0]).contains { $0 is WKWebView })
    XCTAssertEqual(resources.activeWebSurfaceCount, 1, "Only the unrelated blocker owns a WebKit slot")
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    let interaction = try XCTUnwrap(views(fixture.hosts[0]).compactMap { $0 as? DocumentPaperInteractionView }.first)
    XCTAssertTrue(interaction.admitsInput)
    XCTAssertTrue(interaction.isUserInteractionEnabled)
    let text = (interaction.accessibilityElements ?? []).compactMap { ($0 as? UIAccessibilityElement)?.accessibilityLabel }.joined()
    XCTAssertTrue(text.contains("Visible native article"))
    var destination: DocumentLinkDestination?
    fixture.replaceLinkNavigation { destination = $0 }
    try fixture.activateLink(in: paper)
    XCTAssertEqual(destination, .page(1))
    try await fixture.assertPaperReceivesNativeHit(paper)
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: fixture.link(in: paper)), .scene)
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: sourceButton(in: fixture.hosts[0])), .scene)
    try await assertSourceRequest(fixture, document: document)
  }

  func testSourceReplacementAtomicallyRetiresOldActionsWithTheOldPaperCut() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source:
      "Original article. \\hyperlink{target}{Old link}\\newpage\\hypertarget{target}{}Target.")])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await ready(fixture)
    let paper = try XCTUnwrap(fixture.paper(in: 0)), oldRaster = try XCTUnwrap(paper.raster)
    let oldLink = try XCTUnwrap(fixture.link(in: paper)), oldSource = try XCTUnwrap(sourceButton(in: fixture.hosts[0]))
    fixture.replaceSource(fileID: "body", source:
      "Replacement article. \\hyperlink{target}{New link}\\newpage\\hypertarget{target}{}Target.")
    XCTAssertTrue(paper.raster === oldRaster, "The preceding readable print remains until its successor is ready")
    XCTAssertFalse(oldLink.accessibilityActivate())
    XCTAssertFalse(oldSource.accessibilityActivate())
    try await ready(fixture)
    XCTAssertTrue(fixture.paper(in: 0) === paper)
    XCTAssertEqual(paper.raster?.page.artifact.document, fixture.document)
    XCTAssertNotEqual(paper.raster?.sourceKey, oldRaster.sourceKey)
    XCTAssertFalse(oldLink.accessibilityActivate(), "A retired native action cannot borrow the next source's admission")
    XCTAssertFalse(oldSource.accessibilityActivate())
    let interaction = try XCTUnwrap(views(fixture.hosts[0]).compactMap { $0 as? DocumentPaperInteractionView }.first)
    XCTAssertTrue(interaction.admitsInput && interaction.isUserInteractionEnabled)
    let text = (interaction.accessibilityElements ?? []).compactMap { ($0 as? UIAccessibilityElement)?.accessibilityLabel }.joined()
    XCTAssertTrue(text.contains("Replacement article")); XCTAssertFalse(text.contains("Original article"))
    XCTAssertEqual(fixture.link(in: paper)?.accessibilityLabel, "New link")
    try await assertSourceRequest(fixture, document: fixture.document)
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 0)
  }

  func testFailedTeXKeepsOnlyShownCurrentPaperTextAccessibleUntilRepair() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source:
      "Last readable article. \\hyperlink{target}{Old link}\\newpage\\hypertarget{target}{}Neighbour article.")], width: 720, height: 400)
    let fixture = try ProgramFixture(document: document)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    let lifetime = owner.retainOpenDocument()
    defer { fixture.close(); lifetime.close() }
    try await ready(fixture)
    let paper = try XCTUnwrap(fixture.paper(in: 0)), original = try XCTUnwrap(paper.raster)
    XCTAssertTrue(fixture.hosts[0].hasCanonicalPaperProjection, "The fixture must mount the measured landscape paper before exercising fallback")
    let interaction = try XCTUnwrap(views(fixture.hosts[0]).compactMap { $0 as? DocumentPaperInteractionView }.first)
    let oldLink = try XCTUnwrap(fixture.link(in: paper)), oldSource = try XCTUnwrap(sourceButton(in: fixture.hosts[0]))
    func text() -> String {
      (interaction.accessibilityElements ?? []).compactMap { ($0 as? UIAccessibilityElement)?.accessibilityLabel }.joined()
    }
    XCTAssertTrue(text().contains("Last readable article"))
    fixture.hosts[0].alpha = 0; fixture.setVisible(false)
    XCTAssertTrue(interaction.accessibilityElements?.isEmpty == true)
    fixture.replaceSource(fileID: "body", source: "\\NotebookUndefinedCommand")
    let deadline = ContinuousClock.now + .seconds(10)
    while fixture.preparationErrors.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(fixture.preparationErrors.isEmpty, fixture.diagnostics)
    XCTAssertTrue(paper.raster === original)

    fixture.hosts[0].alpha = 1; fixture.setVisible(true)
    await owner.observePendingPresentationWork()
    fixture.window.layoutIfNeeded()
    XCTAssertTrue(SceneSourceVisibility.isVisible(paper))
    XCTAssertFalse(fixture.canonicalPaper(in: 0))
    XCTAssertFalse(interaction.admitsInput)
    XCTAssertFalse(interaction.accessibilityElementsHidden)
    XCTAssertTrue(text().contains("Last readable article"), "The visible previous PDF remains readable under its source-error banner")
    XCTAssertFalse((interaction.accessibilityElements ?? []).contains { $0 is UIButton })
    XCTAssertFalse(oldLink.isAccessibilityElement); XCTAssertFalse(oldSource.isAccessibilityElement)
    XCTAssertFalse(oldLink.accessibilityActivate()); XCTAssertFalse(oldSource.accessibilityActivate())

    fixture.select(1)
    XCTAssertTrue(interaction.accessibilityElements?.isEmpty == true, "A neighbour cannot expose the current page's article")
    fixture.select(0)
    XCTAssertTrue(text().contains("Last readable article"))
    lifetime.parkForReturn(); fixture.retirePresentation(0)
    XCTAssertTrue(interaction.accessibilityElements?.isEmpty == true, "Retiring the physical Entry also retires its AX reading route")
    fixture.replaceSource(fileID: "body", source: "Repaired article. \\hyperlink{target}{New link}\\newpage\\hypertarget{target}{}Target.")
    lifetime.resume(); fixture.restorePresentation(0)
    try await ready(fixture)
    let repaired = try XCTUnwrap(views(fixture.hosts[0]).compactMap { $0 as? DocumentPaperInteractionView }.first)
    let repairedText = (repaired.accessibilityElements ?? []).compactMap { ($0 as? UIAccessibilityElement)?.accessibilityLabel }.joined()
    XCTAssertTrue(repairedText.contains("Repaired article")); XCTAssertFalse(repairedText.contains("Last readable article"))
    XCTAssertTrue(repaired.admitsInput)
    XCTAssertTrue((repaired.accessibilityElements ?? []).contains { $0 is UIButton })
  }

  private func assertSourceRequest(_ fixture: ProgramFixture, document: DocumentDocument) async throws {
    let expected = try XCTUnwrap(document.files.first { $0.id == "body" })
    let version = document.fileVersion(fileID: expected.id)
    let requested = expectation(description: "Installed native source address")
    let observer = NotificationCenter.default.addObserver(forName: DocumentSourceRequest.notification, object: nil, queue: .main) { note in
      guard let request = note.object as? DocumentSourceRequest, request.documentID == document.id else { return }
      XCTAssertEqual(request.file, expected); XCTAssertEqual(request.version, version)
      XCTAssertGreaterThanOrEqual(request.offset, 0); XCTAssertLessThanOrEqual(request.offset, expected.source.utf16.count)
      requested.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    XCTAssertTrue(try XCTUnwrap(sourceButton(in: fixture.hosts[0])).accessibilityActivate())
    await fulfillment(of: [requested], timeout: 2)
  }
  private func sourceButton(in host: UIView) -> UIButton? {
    views(host).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "document-source-body" }
  }
  private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
  private func ready(_ fixture: ProgramFixture) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(fixture.canonicalPaper(in: 0) && fixture.presents(.paper) && fixture.hosts[0].isUserInteractionEnabled), .now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(fixture.canonicalPaper(in: 0) && fixture.presents(.paper), fixture.diagnostics)
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled, fixture.diagnostics)
  }
}
