import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class AgentTableRenderingTests: XCTestCase {
  func testSmallSettledZoomRefinesTheMountedTableWithoutReloadingContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    addTeardownBlock { @MainActor in
      host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil
      let saved = await model.shutdown(); XCTAssertTrue(saved)
      if saved { try FileManager.default.removeItem(at: root) }
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 100_000, y: 100_000))
    let documentCenter = WorldPoint(x: 498, y: -650)
    let documentID = try XCTUnwrap(model.createDocument(at: documentCenter, paperSize: .a4))
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    var document = try model.store.loadDocument(documentID)
    XCTAssertTrue(document.replaceContent(blocks: [.markdown(id: "body", source: "# Возвращение к чёткой таблице\n\nЧитаем документ, затем продолжаем работу на доске.")], actor: model.actorID))
    _ = try model.store.saveMergedDocument(document)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    let before = try model.store.loadBoard(items: model.store.loadIndex().items)
    var after = before
    let bars = stride(from: 36, to: 924, by: 8).map { "<rect x='\($0)' y='740' width='4' height='60'/>" }.joined()
    let rows = (0..<6).map { row in
      "<rect x='36' y='\(170 + row * 80)' width='888' height='80' fill='\(row % 2 == 0 ? "#d7edf7" : "#fffefb")'/><text x='60' y='\(222 + row * 80)' font-size='27'>\(row)    кот    0.8    −0.2    0.1    0.6</text>"
    }.joined()
    let element = SpatialElement(id: "table-sampling", surface: .board(boardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 996.1463372938888, height: 868.8986829907476), worldOrigin: .zero,
      source: "A synthetic vector table with reading-size text and four-unit sampling bars",
      html: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 960 840'><rect width='960' height='840' fill='#fffefb'/><g fill='#17323f' font-family='-apple-system'><text x='36' y='56' font-size='42' font-weight='700'>Таблица эмбеддингов GPT</text><text x='36' y='96' font-size='23'>Текст и цифры остаются чёткими при увеличении</text>\(rows)\(bars)</g></svg>",
      css: "html,body,svg{margin:0;width:100%;height:100%;display:block}", stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(after.upsertElement(element, in: boardID, expected: nil, actor: model.actorID))
    _ = try model.store.saveBoardEdits(before: before, after: after)
    await model.reloadExternalChanges()?.value
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    host.rootView = AnyView(SpatialWorkspaceView().environment(model).environment(\.displayScale, 2).ignoresSafeArea())
    window.rootViewController = host; window.makeKeyAndVisible()
    let originalInk = model.spatialInk
    // The second enlargement stays inside the former 1.6x coverage shortcut.
    // Jumping directly from the overview to reading scale misses this defect.
    for zoom in [0.13101832425163298, 0.5, 0.7027193990126275, 0.62] {
      let presence = SessionPresence(boardID: boardID, mode: .board,
        camera: .init(center: .init(x: element.frame.width / 2, y: element.frame.height / 2), scale: zoom),
        viewport: .init(x: 834, y: 1194))
      if zoom == 0.7027193990126275 {
        let opened = SessionPresence(boardID: boardID, mode: .document,
          camera: .init(center: documentCenter, scale: model.itemGeometry(documentID).fitScale(viewport: presence.viewport)),
          viewport: presence.viewport, focusedItemID: documentID, openProgress: 1)
        model.selectItem(documentID)
        model.updatePresence(opened, settled: true)
        let deadline = ContinuousClock.now + .seconds(8)
        var text = ""
        while !text.contains("Возвращение к чёткой таблице"), ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(30))
          if let web = webViews(host.view).first {
            text = (try? await web.evaluateJavaScript("document.querySelector('#document')?.innerText ?? ''")) as? String ?? ""
          }
        }
        XCTAssertTrue(text.contains("Возвращение к чёткой таблице"), "The real document must render before testing its return")
      }
      if let shown = model.compositionTiles.published {
        model.updatePresence(presence, settled: false)
        try await Task.sleep(for: .milliseconds(100))
        if zoom != 0.7027193990126275 {
          XCTAssertTrue(model.compositionTiles.published === shown,
            "An enlargement inside the painted area projects the same pixels until settlement")
        }
      }
      // The pose does not change on lift: the settlement itself must request
      // readable density rather than waiting for one more camera movement.
      model.updatePresence(presence, settled: true)
      let deadline = ContinuousClock.now + .seconds(10)
      let minimumScale = floor(element.frame.width * zoom * 2) / element.frame.width
      while (model.compositionTiles.published == nil || model.scenePreparationPending || model.compositionTiles.isPreparing
        || SceneRenderResources.shared.image(for: agentElementSnapshotSource(element), minimumScale: minimumScale) == nil),
        ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertFalse(model.scenePreparationPending, model.compositionTiles.failure ?? "Table preparation did not finish")
      let releaseDeadline = ContinuousClock.now + .seconds(3)
      while !webViews(host.view).isEmpty, ContinuousClock.now < releaseDeadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertTrue(webViews(host.view).isEmpty, "A closed selected document cannot retain invisible live pages over the board")
      let closedCover = try XCTUnwrap(model.compositionTiles.published?.frame.workset(boardID: boardID).items.first { $0.id == documentID })
      XCTAssertTrue(WorkspaceSceneProjection.mountsContent(of: closedCover, in: presence),
        "The visible closed cover remains mounted; culling must not hide a page lifetime defect")
      XCTAssertTrue(model.compositionTiles.published?.plan.allowsLive(.item(documentID), in: .board(boardID)) == true)
      try await Task.sleep(for: .milliseconds(150))
      let raster = try XCTUnwrap(SceneRenderResources.shared.retainRaster(for: agentElementSnapshotSource(element)))
      let source = XCTAttachment(image: raster.image); source.name = "table-source-\(zoom)-density-\(raster.pixelScale)"; source.lifetime = .keepAlways; add(source)
      let output = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      let shown = XCTAttachment(image: output); shown.name = "table-mounted-\(zoom)"; shown.lifetime = .keepAlways; add(shown)
      let presenters = descendants(host.view)
      let descriptions = presenters.map { "\($0.bounds), contents=\($0.layer.contents.map { ($0 as! CGImage).width } ?? 0), scale=\($0.layer.contentsScale)" }
      let description = "zoom=\(zoom) cached=\(raster.pixelScale) frame=\(model.compositionTiles.published?.frame.pixelScales[boardID] ?? -1) presenters=\(descriptions)"
      let report = XCTAttachment(string: description); report.name = "table-density-\(zoom)"; report.lifetime = .keepAlways; add(report)
      XCTAssertGreaterThanOrEqual(raster.pixelScale, minimumScale, description)
      XCTAssertEqual(presenters.count, 1, "A new density replaces the same material, not an overlapping copy")
      for presenter in presenters {
        let shownPixels = try XCTUnwrap(presenter.layer.contents) as! CGImage
        XCTAssertGreaterThanOrEqual(shownPixels.width, Int(floor(element.frame.width * zoom * 2)), description)
        XCTAssertFalse(presenter.layer.shouldRasterize)
      }
      if zoom >= 0.5 { try assertFineEdges(output, element: element, zoom: zoom) }
      XCTAssertEqual(model.presence?.camera, presence.camera)
      XCTAssertEqual(model.spatialInk, originalInk)
      XCTAssertEqual(try model.store.readSpatialElement(boardID: boardID, elementID: element.id)?.html, element.html)
      raster.release()
    }
  }

  /// Inspect the actually mounted pixels, not only the cache metadata. Four
  /// SVG-unit bars must retain ink and gaps at reading scale; a blank surface
  /// or a severely stretched overview cannot pass as a ready table.
  private func assertFineEdges(_ image: UIImage, element: SpatialElement, zoom: Double) throws {
    let cg = try XCTUnwrap(image.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let projection = element.frame.height / 840 * zoom
    let y = Int((image.size.height / 2 + (770 - 420) * projection) * image.scale)
    let left = Int((image.size.width / 2 - 350 * projection) * image.scale)
    let right = Int((image.size.width / 2 + 350 * projection) * image.scale)
    let line = (left..<right).map { Int(data[y * context.bytesPerRow + $0 * 4]) }
    XCTAssertLessThan(try XCTUnwrap(line.min()), 40)
    XCTAssertGreaterThan(try XCTUnwrap(line.max()), 235)
    XCTAssertGreaterThan(line.filter { $0 < 40 || $0 > 235 }.count, line.count / 2)
  }

  private func descendants(_ view: UIView) -> [AgentSnapshotRasterView] {
    (view as? AgentSnapshotRasterView).map { [$0] } ?? view.subviews.flatMap(descendants)
  }

  private func webViews(_ view: UIView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
  }
}
