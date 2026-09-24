import AppKit
import NotebookCore
import SwiftUI
import XCTest
@testable import Notebook

@MainActor final class MacPagePublicationTests: XCTestCase {
  func testPageChangePublishesStaticMaterialAsOnePage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root), model = fixture.model
    retainNotebookUntilTeardown(model, removing: root)
    try await fixture.start(showingPage: true)
    let item = try XCTUnwrap(model.workspace?.selectedItemID)
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: item, expectedRoot: model.notebookPageRoot(item)!), 1)
    let appended = await model.finishPendingPersistence(); XCTAssertTrue(appended)
    var page = try XCTUnwrap(model.activePage)
    let paths = (0..<250).map { "<path d='M0 \($0 % 120)L150 \(($0 * 7) % 120)'/>" }.joined()
    let elements = (0..<35).map { n in
      AgentElement(id: "static-\(n)", kind: .web,
        frame: .init(x: 30 + Double(n % 5)*155, y: 45 + Double(n / 5)*155, width: 145, height: 140),
        source: "", html: "<svg xmlns='http://www.w3.org/2000/svg' width='100%' height='100%' viewBox='0 0 150 140'><g stroke='black' stroke-width='.2'>\(paths)</g><rect y='125' width='150' height='15' fill='#2288ff'/></svg>")
    }
    XCTAssertTrue(elements.allSatisfy(\.usesNativeSVGRaster))
    XCTAssertTrue(page.replaceElements(elements, actor: model.actorID))
    try fixture.store.savePage(page); await model.reloadExternalChanges()?.value
    await model.prepareNotebookPage(at: 0, in: item)
    XCTAssertEqual(model.selectNotebookPage(0, notebookID: item, expectedRoot: model.notebookPageRoot(item)!), 0)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let host = NSHostingView(rootView: NotebookMacCanvas(documentLayout: .constant(nil)).environment(model))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 1250),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    defer { window.contentView = nil; window.close() }
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    try await fixture.waitUntil {
      model.presence?.viewport.x == 900
        && views(host).compactMap { $0 as? MacNotebookPageView }.first?.presentedPageView != nil
    }
    host.layoutSubtreeIfNeeded()
    let reader = try XCTUnwrap(views(host).compactMap { $0 as? MacNotebookPageView }.first)
    let original = try XCTUnwrap(reader.presentedPageView)
    XCTAssertEqual(views(original).compactMap { $0 as? AgentSnapshotRasterView }.count, 0)
    let start = ContinuousClock.now
    XCTAssertTrue(model.notebookPageNavigation.send(.jump(1), ownerID: item, source: model.notebookPageRoot(item)!))
    var capturedFirstFrame = false
    var samples: [(Double, Int)] = [], lastCount = -1
    repeat {
      let count = reader.presentedPageView.map(views)?.compactMap { $0 as? AgentSnapshotRasterView }
        .filter { SceneSourceVisibility.isVisible($0) && ($0.image != nil || $0.layer?.sublayers?.contains { $0.contents != nil } == true) }.count
        ?? 0
      if count == 0 { XCTAssertTrue(reader.presentedPageView === original, "Preparation retains the actual source paper, not a blank replacement") }
      if count != lastCount {
        let elapsed = start.duration(to: .now).components
        samples.append((Double(elapsed.seconds)*1000 + Double(elapsed.attoseconds)/1e15, count))
        lastCount = count
      }
      if count > 0, !capturedFirstFrame {
        capturedFirstFrame = true
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
          host.cacheDisplay(in: host.bounds, to: rep)
          if let png = rep.representation(using: .png, properties: [:]) {
            let shot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            shot.name = "First target page, \(count) installed rasters (AppKit capture, not display timing)"
            shot.lifetime = .keepAlways; add(shot)
          }
        }
      }
      if count == elements.count { break }
      try await Task.sleep(for: .milliseconds(4))
    } while start.duration(to: .now) < .seconds(5)
    let note = XCTAttachment(string: "Installed visible rasters (ms, count), not physical frame timing: \(samples)")
    note.name = "Whole-page publication"; note.lifetime = .keepAlways; add(note)
    XCTAssertEqual(lastCount, elements.count)
    XCTAssertEqual(model.activePage?.id, page.id)
    XCTAssertFalse(samples.contains { $0.1 > 0 && $0.1 < elements.count },
      "The ordinary reader exposes partially prepared static material: \(samples)")
    let prepared = try XCTUnwrap(reader.presentedPageView)
    var warm: [Double] = []
    for index in [0, 1, 0, 1, 0, 1, 0, 1, 0, 1] {
      let began = ContinuousClock.now, expected = index == 0 ? original : prepared
      XCTAssertTrue(model.notebookPageNavigation.send(.step(index == 0 ? -1 : 1),
        ownerID: item, source: model.notebookPageRoot(item)!))
      while reader.presentedPageView !== expected, began.duration(to: .now) < .milliseconds(150) {
        try await Task.sleep(for: .milliseconds(2))
      }
      let duration = began.duration(to: .now).components
      let ms = Double(duration.seconds)*1000 + Double(duration.attoseconds)/1e15
      warm.append(ms)
      XCTAssertTrue(reader.presentedPageView === expected, "Reverse reuses the actual ready paper")
      XCTAssertEqual(model.notebookPageIndex(try XCTUnwrap(model.activePage?.id), in: item), index)
      XCTAssertLessThanOrEqual(ms, 100, "Prepared page installation must not wait for another SVG conversion")
      let rasters = views(expected).compactMap { $0 as? AgentSnapshotRasterView }
        .filter { $0.image != nil || $0.layer?.sublayers?.contains { $0.contents != nil } == true }
      XCTAssertEqual(rasters.count, index == 0 ? 0 : 35)
    }
    let warmed = XCTAttachment(string: "Ten prepared page installations (ms; not display timing): \(warm)")
    warmed.name = "Prepared reverse turns"; warmed.lifetime = .keepAlways; add(warmed)
  }
}
