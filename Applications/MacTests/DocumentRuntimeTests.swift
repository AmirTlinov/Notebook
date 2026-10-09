import AppKit
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentRuntimeTests: XCTestCase {
  func testPaperPreparesNativePixelsWhileEveryBrowserSlotIsOccupied() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let occupied = try await resources.acquireWebSurface(priority: .input)
    defer { occupied.release() }
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source: "\\section{Native paper}Text and a real \\href{https://example.org}{link}.")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let result = try await DocumentSnapshotCache.shared.prepare(document: document, state: state,
      pageIndex: 0, resources: resources, pixelWidth: 320)
    defer { result.release() }
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertNotNil(DocumentRenderRegistry.shared.entry(document: document, pageIndex: 0))
    XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0))
    let pixels = try XCTUnwrap(result.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertEqual(pixels.width, 320)
  }

  func testProgramPreviewUsesPinnedStateAndCannotPublishBootCommits() async throws {
    let store = try isolatedStore(); defer { try? FileManager.default.removeItem(at: store.root) }
    let document = DocumentTestFiles.document(contents: [.program(id: "counter", html: """
      <div style="position:absolute;inset:0;background:#00ff00">
        <div style="position:absolute;left:0;right:0;bottom:0;height:4px;background:#ff0000"></div>
        <div style="position:absolute;top:0;bottom:0;right:0;width:4px;background:#0000ff"></div>
      </div>
      """,
      javaScript: """
      const changed=notebook.commit({count:99});
      if(changed || notebook.state.count!==7) throw Error('Preview replaced its pinned state');
      notebook.lifecycle({checkpoint:()=>notebook.state});notebook.ready(Promise.resolve());
      """,
      initialState: .object(["count": .number(1)]), height: 120)])
    var state = DocumentStateJournal(id: document.id, actor: UUID())
    _ = state.commit(instanceID: "counter", value: .object(["count": .number(7)]), actor: state.stamp.actor)
    let before = try store.workspaceHeader()
    let resources = SceneRenderResources()
    let raster: RasterLease
    do {
      raster = try await DocumentSnapshotCache.shared.prepare(document: document, state: state,
        pageIndex: 0, resources: resources, programStore: store, pixelWidth: 320)
    } catch {
      XCTFail("Pinned preview failed: \(String(reflecting: type(of: error))): \(error)")
      return
    }
    defer { raster.release() }
    XCTAssertEqual(raster.source, .document(id: document.id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0)))
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(DocumentRenderRegistry.shared.entry(document: document, pageIndex: 0)?.programs.first?.status, .ready)
    XCTAssertEqual(try store.workspaceHeader(), before)
    let layout = try XCTUnwrap(DocumentRenderRegistry.shared.layout(document: document))
    let region = try XCTUnwrap(layout.regions(on: 0).first { $0.id == "counter" && $0.kind == .program })
    let pixels = try XCTUnwrap(raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let paper = layout.paper(on: 0), scale = Double(pixels.width) / paper.surfaceWidth
    XCTAssertEqual(pixels.width, 320)
    XCTAssertEqual(pixels.height, Int(ceil(320 * paper.surfaceHeight / paper.surfaceWidth)))
    // Last pixel centers inside the authored frame catch WebKit's former
    // ~1.3-pixel bottom truncation, even when a stretched image looks plausible.
    let bottom = try pixel(pixels, x: Int((region.frame.x + region.frame.width / 2) * scale),
      y: Int(floor((region.frame.y + region.frame.height) * scale - 0.5)))
    XCTAssertGreaterThan(Int(bottom[0]), Int(bottom[1]) + 30)
    XCTAssertGreaterThan(Int(bottom[0]), Int(bottom[2]) + 30)
    let right = try pixel(pixels, x: Int(floor((region.frame.x + region.frame.width) * scale - 0.5)),
      y: Int((region.frame.y + region.frame.height / 2) * scale))
    XCTAssertGreaterThan(Int(right[2]), Int(right[0]) + 30)
    XCTAssertGreaterThan(Int(right[2]), Int(right[1]) + 30)
  }

  func testOnlyProgramsOnTheRequestedPageExecuteAndFailuresRetainTheirAddress() async throws {
    let store = try isolatedStore(); defer { try? FileManager.default.removeItem(at: store.root) }
    let document = DocumentTestFiles.document(contents: [.program(id: "healthy", html: "<p>Ready</p>", height: 100),
      .tex(id: "break", source: "\\newpage"),
      .program(id: "failed", html: "<p>Broken</p>", javaScript: "notebook.ready(Promise.reject(Error('addressed author failure')));", height: 100)])
    let state = DocumentStateJournal(id: document.id, actor: UUID()), resources = SceneRenderResources()
    let first = try await DocumentSnapshotCache.shared.prepare(document: document, state: state,
      pageIndex: 0, resources: resources, programStore: store, pixelWidth: 240)
    first.release()
    let layout = try XCTUnwrap(DocumentRenderRegistry.shared.layout(document: document))
    let page = try XCTUnwrap(layout.regions.first { $0.id == "failed" && $0.kind == .program }).pageIndex
    XCTAssertGreaterThan(page, 0)
    do {
      let unexpected = try await DocumentSnapshotCache.shared.prepare(document: document, state: state,
        pageIndex: page, resources: resources, programStore: store, pixelWidth: 240)
      unexpected.release(); XCTFail("Failed authored readiness cannot produce a successful receipt")
    } catch let failure as DocumentRenderingFailure {
      XCTAssertEqual(failure.diagnostics.first?.elementID, "failed")
      XCTAssertTrue(failure.diagnostics.first?.message.contains("addressed author failure") == true)
      XCTAssertNotNil(failure.buildID)
      XCTAssertEqual(failure.programs.first { $0.instanceID == "failed" }?.status, .failed)
    }
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  func testTallProgramUsesExactCanonicalContinuationCuts() async throws {
    let store = try isolatedStore(); defer { try? FileManager.default.removeItem(at: store.root) }
    let html = """
      <div style="position:relative;height:2048px">
        <div style="height:700px;background:#ff0000"></div><div style="height:700px;background:#00ff00"></div><div style="height:648px;background:#0000ff"></div>
        <div style="position:absolute;top:0;bottom:0;right:0;width:4px;background:#ff00ff"></div>
        <div style="position:absolute;bottom:0;left:0;right:0;height:4px;background:#00ffff"></div>
      </div>
      """
    let document = DocumentTestFiles.document(contents: [.program(id: "tall", html: html, height: 2048)])
    let state = DocumentStateJournal(id: document.id, actor: UUID()), resources = SceneRenderResources()
    let session = DocumentRenderSession(documentID: document.id), source = session.source(document, store: store)
    _ = try await source.printedSource(resources: resources)
    let layout = try XCTUnwrap(source.layout)
    let fragments = layout.regions.filter { $0.kind == .program && $0.id == "tall" }
    XCTAssertGreaterThan(layout.pageCount, 1)
    XCTAssertTrue(fragments.contains { $0.sourceOffset - floor($0.sourceOffset) > 0.01 },
      "This fixture must exercise a fractional continuation origin")
    for page in Set(fragments.map(\.pageIndex)).sorted() {
      try await DocumentSnapshotCache.shared.withPreparedPage(document: document, state: state, pageIndex: page,
        resources: resources, programStore: store, isolationID: nil, renderSession: session) { renderer in
        let raster = try await renderer.retainPreparedSnapshot(pixelWidth: 640, waitsForRasterAdmission: true)
        defer { raster.release() }
        let cg = try XCTUnwrap(raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let fragment = try XCTUnwrap(fragments.first { $0.pageIndex == page }), paper = layout.paper(on: page)
        let x = Int((fragment.frame.x + fragment.frame.width / 2) * Double(cg.width) / paper.surfaceWidth)
        let y = Int((fragment.frame.y + fragment.frame.height / 2) * Double(cg.height) / paper.surfaceHeight)
        let color = try pixel(cg, x: x, y: y)
        let viewportY = fragment.sourceOffset + (Double(y) + 0.5) * paper.surfaceHeight / Double(cg.height) - fragment.frame.y
        let expected = min(2, Int(viewportY / 700))
        for channel in 0..<3 {
          if channel == expected { XCTAssertGreaterThan(color[channel], 230) }
          else { XCTAssertLessThan(color[channel], 25) }
        }
        let scale = Double(cg.width) / paper.surfaceWidth
        let right = try pixel(cg, x: Int(floor((fragment.frame.x + fragment.frame.width) * scale - 0.5)),
          y: Int((fragment.frame.y + fragment.frame.height / 2) * scale))
        XCTAssertGreaterThan(Int(right[0]), Int(right[1]) + 30)
        XCTAssertGreaterThan(Int(right[2]), Int(right[1]) + 30)
        if fragment.sourceOffset + fragment.frame.height >= 2048 - 1.0 / 32 {
          let bottom = try pixel(cg, x: x,
            y: Int(floor((fragment.frame.y + fragment.frame.height) * scale - 0.5)))
          XCTAssertGreaterThan(Int(bottom[1]), Int(bottom[0]) + 30)
          XCTAssertGreaterThan(Int(bottom[2]), Int(bottom[0]) + 30)
        }
        XCTAssertEqual(source.preparationCount, 1); XCTAssertEqual(source.measurementCount, 1)
      }
      XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    }
  }

  func testRegistryReleasesUninstalledLayoutAfterItsLastRasterIsEvicted() async throws {
    let resources = SceneRenderResources()
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source: "Temporary paper")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var raster: RasterLease? = try await DocumentSnapshotCache.shared.prepare(document: document, state: state,
      pageIndex: 0, resources: resources, pixelWidth: 240)
    weak var layout = DocumentRenderRegistry.shared.layout(document: document)
    XCTAssertNotNil(layout)
    XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0))
    raster?.release(); raster = nil
    let source = SceneRasterSource.document(id: document.id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0))
    let evicted = expectation(description: "The last unpinned document raster is evicted")
    let observer = NotificationCenter.default.addObserver(forName: SceneRenderResources.didChange,
      object: nil, queue: .main) { note in
        guard note.object as? UUID == document.id else { return }
        MainActor.assumeIsolated {
          if resources.image(for: source) == nil { evicted.fulfill() }
        }
      }
    defer { NotificationCenter.default.removeObserver(observer) }
    resources.handleMemoryPressure(.warning)
    await fulfillment(of: [evicted], timeout: 8)
    XCTAssertNil(resources.image(for: source))
    XCTAssertNil(layout)
    XCTAssertEqual(DocumentRenderRegistry.shared.layoutReferenceCount(documentID: document.id), 0)
  }

  private func isolatedStore() throws -> NotebookStore {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("native-export-" + UUID().uuidString))
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    return store
  }

  private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: .init(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    }
    return bytes
  }
}
