import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class NotebookCoverPresentationTests: XCTestCase {
  @MainActor
  func testWholeCoverSendFreezesItsNativePixelsWithoutOverlappingNeighborOrLaterSource() async throws {
    let fixture = try await makeFixture()
    let model = fixture.model, itemID = fixture.itemID
    let presence = try XCTUnwrap(model.presence), cohort = try XCTUnwrap(model.compositionTiles.published)
    let item = try XCTUnwrap(model.presentedItem(id: itemID, cohort: cohort, presence: presence))
    let bounds = item.geometry.screenFrame(center: item.center, camera: presence.camera, viewport: presence.viewport)
    let expected = try XCTUnwrap(NotebookCoverPresentedSources.current(model: model, itemID: itemID, boardID: fixture.boardID))
    let overlay = UIView(frame: .init(x: bounds.x + 20, y: bounds.y + 20, width: 180, height: 120))
    overlay.backgroundColor = .green; fixture.window.addSubview(overlay)
    XCTAssertTrue(fixture.window.bounds.intersects(overlay.frame))
    var displayedGreen = 0
    let overlapDeadline = ContinuousClock.now + .seconds(3)
    while displayedGreen <= 1_000, ContinuousClock.now < overlapDeadline {
      try await Task.sleep(for: .milliseconds(10))
      let screen = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
        fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: false)
      }
      displayedGreen = try colors(screen).green
    }
    XCTAssertGreaterThan(displayedGreen, 1_000, "The overlapping neighbor must actually be painted before Send")
    attachWindow(fixture.window, name: "whole-cover-before-send-with-overlapping-green-neighbor")
    let selection = try XCTUnwrap(NotebookAttentionProjection.capture(
      start: .init(x: bounds.x + 2, y: bounds.y + 2),
      end: .init(x: bounds.x + bounds.width - 2, y: bounds.y + bounds.height - 2),
      model: model, presence: presence, cohort: cohort,
      installedInk: model.compositionTiles.surfaceRegistry.installedSources(), itemID: itemID))
    let references = try selection.resolvedReferences()
    let reference = try XCTUnwrap(references.first { $0.target.kind == .cover && $0.elementID == nil })
    let region = try XCTUnwrap(reference.region)
    model.publishHumanContext(selection)
    let contextSaved = await model.finishPendingPersistence(); XCTAssertTrue(contextSaved)
    let contextDeadline = ContinuousClock.now + .seconds(5)
    while model.coverPresentations.captureFailure(itemID: itemID, expected: expected) != nil,
      ContinuousClock.now < contextDeadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNil(model.coverPresentations.captureFailure(itemID: itemID, expected: expected))
    let sent = selection.freezingSubmissionVisuals()
    overlay.removeFromSuperview()
    var hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    var element = try XCTUnwrap(hierarchy.board(fixture.boardID)?.elements.first { $0.id == "cover-red" })
    let before = element.stamp
    XCTAssertTrue(element.update(source: "Blue cover", html: Self.html("#0000ff"), actor: model.actorID))
    XCTAssertTrue(hierarchy.upsertElement(element, in: fixture.boardID, expected: before, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    XCTAssertNotEqual(NotebookCoverPresentedSources.current(model: model, itemID: itemID, boardID: fixture.boardID), expected,
      "An installed old cohort cannot certify that its source is still the latest accepted model source")
    let held = SceneRenderResources.shared.rasterAdmission.heldBytes
    XCTAssertThrowsError(try model.coverPresentations.capture(itemID: itemID, expected: expected,
      region: region, resources: .shared), "A changed source cannot fill the old selection with later pixels")
    XCTAssertEqual(SceneRenderResources.shared.rasterAdmission.heldBytes, held)
    let result = try await sent.renderPinnedImages(references: references)
    let pinned = try XCTUnwrap(result.images[reference.id], result.unavailable.description)
    try pinned.validate(reference: reference)
    let image = try XCTUnwrap(UIImage(data: pinned.png))
    let counts = try colors(image)
    XCTAssertGreaterThan(counts.red, 1_000)
    XCTAssertGreaterThan(counts.black, 400, "The same physical cover owner includes its installed handwriting")
    XCTAssertEqual(counts.green, 0, "A physically overlapping window sibling is not part of this cover")
    XCTAssertEqual(counts.blue, 0, "The exact Send event owns the retained pixels")
    let attachment = XCTAttachment(image: image); attachment.name = "whole-cover-send-red-without-overlapping-green-or-later-blue"
    attachment.lifetime = .keepAlways; add(attachment)
  }

  @MainActor
  func testUnavailableHiddenDetachedAndCurlCoversDoNotAllocateSubmissionImages() async throws {
    let fixture = try await makeFixture()
    let model = fixture.model
    let expected = try XCTUnwrap(NotebookCoverPresentedSources.current(model: model, itemID: fixture.itemID, boardID: fixture.boardID))
    let region = PageRect(x: 0, y: 0, width: 100, height: 100)
    let resources = SceneRenderResources(byteLimit: 8 * 1024 * 1024)
    XCTAssertThrowsError(try model.coverPresentations.capture(itemID: UUID(), expected: expected, region: region, resources: resources))
    func descendants(_ controller: UIViewController) -> [UIViewController] { [controller] + controller.children.flatMap(descendants) }
    let controller = try XCTUnwrap(descendants(try XCTUnwrap(fixture.window.rootViewController)).compactMap { $0 as? IPadCoverOpeningController }.first)
    controller.view.isHidden = true
    XCTAssertThrowsError(try model.coverPresentations.capture(itemID: fixture.itemID, expected: expected, region: region, resources: resources))
    controller.view.isHidden = false
    let presence = try XCTUnwrap(model.presence)
    model.updatePresence(.init(boardID: fixture.boardID, mode: .cover,
      camera: presence.camera, viewport: presence.viewport,
      focusedItemID: fixture.itemID, openProgress: 0.5), settled: true)
    XCTAssertThrowsError(try model.coverPresentations.capture(itemID: fixture.itemID, expected: expected, region: region, resources: resources))
    controller.view.removeFromSuperview()
    XCTAssertThrowsError(try model.coverPresentations.capture(itemID: fixture.itemID, expected: expected, region: region, resources: resources))
    controller.uninstallPresentation()
    XCTAssertThrowsError(try model.coverPresentations.capture(itemID: fixture.itemID, expected: expected, region: region, resources: resources))
    XCTAssertEqual(resources.rasterAdmission.heldBytes, 0, "Every unavailable guard executes before allocating a native image")
  }

  @MainActor
  private func makeFixture() async throws -> (model: NotebookAppModel, itemID: UUID, boardID: UUID, window: UIWindow) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID), boardID = try XCTUnwrap(model.presence?.boardID)
    model.moveItem(itemID, to: .zero)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    var hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    let element = SpatialElement(id: "cover-red", surface: .cover(itemID), kind: .web,
      frame: .init(x: 100, y: 300, width: 300, height: 200),
      source: "Red cover", html: Self.html("#ff0000"), stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(hierarchy.upsertElement(element, in: boardID, expected: nil, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    var ink = SpatialInkJournal(stamp: .init(counter: 0, actor: model.actorID))
    let span = SpatialInkSpan(surface: .cover(itemID), samples: [100.0, 350, 600].enumerated().map { index, x in
      .init(point: .init(x: x, y: 650), timeOffset: Double(index) / 10,
        width: 18, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    })
    _ = ink.append(tool: .pen, spans: [span], actor: model.actorID)
    try model.store.saveSpatialInk(ink)
    await model.reloadExternalChanges()?.value
    model.updatePresence(.init(boardID: boardID, mode: .board, camera: .init(scale: 0.32),
      viewport: .init(x: 512, y: 512)), settled: true)
    let window = try await mountNotebookScene(model)
    let deadline = ContinuousClock.now + .seconds(10)
    var failure: String? = "cover_not_mounted"
    while ContinuousClock.now < deadline {
      if let expected = NotebookCoverPresentedSources.current(model: model, itemID: itemID, boardID: boardID) {
        failure = model.coverPresentations.captureFailure(itemID: itemID, expected: expected)
        if failure == nil { break }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    if failure != nil { attachWindow(window, name: "whole-cover-presentation-readiness-failure") }
    XCTAssertNil(failure)
    return (model, itemID, boardID, window)
  }

  private static func html(_ color: String) -> String {
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 300 200'><rect width='300' height='200' fill='\(color)'/></svg>"
  }

  @MainActor
  private func attachWindow(_ window: UIWindow, name: String) {
    let pixels = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
    }
    let attachment = XCTAttachment(image: pixels); attachment.name = name
    attachment.lifetime = .keepAlways; add(attachment)
  }

  private func colors(_ image: UIImage) throws -> (red: Int, green: Int, blue: Int, black: Int) {
    let image = try XCTUnwrap(image.cgImage)
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    }
    var result = (red: 0, green: 0, blue: 0, black: 0)
    for i in stride(from: 0, to: bytes.count, by: 4) {
      if bytes[i] > 220 && bytes[i+1] < 40 && bytes[i+2] < 40 { result.red += 1 }
      if bytes[i] < 40 && bytes[i+1] > 220 && bytes[i+2] < 40 { result.green += 1 }
      if bytes[i] < 40 && bytes[i+1] < 40 && bytes[i+2] > 220 { result.blue += 1 }
      if bytes[i] < 40 && bytes[i+1] < 40 && bytes[i+2] < 40 && bytes[i+3] > 220 { result.black += 1 }
    }
    return result
  }
}
