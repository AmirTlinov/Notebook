import AppKit
import NotebookCore
import SwiftUI
import XCTest
@testable import Notebook

final class WorkspaceAppearanceTests: XCTestCase {
  @MainActor
  func testCameraAndTitleChangesReuseMaterialAndShadowPixels() throws {
    let item = WorkspaceItem.notebook(id: UUID(), title: "First title", pageIDs: [UUID()])
    let geometry = WorkspaceItemGeometry.notebook
    let material = WorkspaceCoverRaster.material(item: item, geometry: geometry)
    let shadow = WorkspaceCoverRaster.shadow(geometry: geometry, lifted: false)
    let lifted = WorkspaceCoverRaster.shadow(geometry: geometry, lifted: true)
    for step in 1...120 {
      let changedTitle = WorkspaceItem.notebook(id: item.id, title: "Title \(step)", pageIDs: item.pageIDs)
      XCTAssertTrue(WorkspaceCoverRaster.material(item: changedTitle, geometry: geometry) === material)
      XCTAssertTrue(WorkspaceCoverRaster.shadow(geometry: geometry, lifted: false) === shadow)
      XCTAssertTrue(WorkspaceCoverRaster.shadow(geometry: geometry, lifted: true) === lifted)
    }
    XCTAssertFalse(shadow === lifted)
    let width = shadow.width
    let height = shadow.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(shadow, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    XCTAssertEqual(pixels[((height / 2) * width + width / 2) * 4 + 3], 0,
      "The live page owns every pixel inside the shadow's paper cutout")
    XCTAssertGreaterThan(pixels[((height / 2) * width + Int(WorkspaceCoverRaster.shadowPadding) - 5) * 4 + 3], 0)
  }

  @MainActor
  func testCoverMaterialsKeepStableIdentityAndReadablePencil() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var ids: [NotebookCoverPalette: UUID] = [:]
    for value in 1...200 {
      let id = UUID(uuidString: String(format: "7E7A4000-0000-4000-8000-%012d", value))!
      ids[NotebookCoverPalette(itemID: id)] = id
    }
    XCTAssertEqual(ids.count, NotebookCoverPalette.allCases.count)
    let titles = ["Мышление\nАмира", "Наблюдения", "Алгебра\nи геометрия", "Исследование отношений и закономерностей", "Заметки", "Замыслы"]
    let items = NotebookCoverPalette.allCases.map { palette in
      WorkspaceItem.notebook(id: ids[palette]!, title: titles[palette.rawValue], pageIDs: [UUID()])
    }
    for item in items {
      let palette = NotebookCoverPalette(itemID: item.id)
      XCTAssertEqual(NotebookCoverPalette(itemID: item.id), palette)
      let (r, g, b) = palette.rgb
      func linear(_ value: Double) -> Double { pow((value + 0.055) / 1.055, 2.4) }
      let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
      XCTAssertGreaterThan((luminance + 0.05) / 0.05, 7, "Чёрное перо читается на каждом материале")
    }
    let scale = 260.0 / WorkspaceItemGeometry.notebook.width
    let height = WorkspaceItemGeometry.notebook.height * scale
    let proof = VStack(spacing: 30) {
      ForEach(0..<2) { row in
        HStack(spacing: 28) {
          ForEach(0..<3) { column in
            self.cover(item: items[row * 3 + column], geometry: .notebook, model: model)
              .background { WorkspaceItemShadow(geometry: .notebook) }
              .scaleEffect(scale).frame(width: 260, height: height)
          }
        }
      }
    }.padding(36).background(Color(red: 0.925, green: 0.928, blue: 0.915))
    let size = CGSize(width: 908, height: height * 2 + 102)
    let image = try attachRendering(proof, size: size, name: "notebook-materials")
    for (index, item) in items.enumerated() {
      let x = 36.0 + Double(index % 3) * 288
      let y = 36.0 + Double(index / 3) * (height + 30)
      let (r, g, b) = NotebookCoverPalette(itemID: item.id).rgb
      let sample = try XCTUnwrap(image.colorAt(x: Int((x + 130) * Double(image.pixelsWide) / size.width),
        y: Int((y + height * 0.65) * Double(image.pixelsHigh) / size.height))?.usingColorSpace(.sRGB))
      XCTAssertEqual(sample.redComponent, r, accuracy: 0.08, "The native cover must contain its material, not a renderer placeholder")
      XCTAssertEqual(sample.greenComponent, g, accuracy: 0.08)
      XCTAssertEqual(sample.blueComponent, b, accuracy: 0.08)
      let sx = Double(image.pixelsWide) / size.width, sy = Double(image.pixelsHigh) / size.height
      var titlePixels = 0
      for py in Int((y + height * 0.14) * sy)..<Int((y + height * 0.52) * sy) {
        for px in Int((x + 260 * 0.145) * sx)..<Int((x + 260 * 0.865) * sx) {
          let color = try XCTUnwrap(image.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
          if printedInk(color) { titlePixels += 1 }
        }
      }
      // Inspect the title area, excluding the footer imprint.
      let minimumTitlePixels = Int(Double(item.title.count * 4) * sx * sy)
      XCTAssertGreaterThanOrEqual(titlePixels, minimumTitlePixels,
        "Every native cover must contain its dark title above the material")
    }
  }

  @MainActor
  func testDocumentTitlePagesKeepPaperProportionsAndReadableLongTitles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let titles = ["Функции\nи графики", "Логарифм и экспонента",
      "Наблюдения за отношениями: как меняются связи между частями и целым",
      String(repeating: "Исследование пространства, формы и движения. ", count: 6).prefix(WorkspaceIndex.maximumTitleLength).description]
    let items = titles.map { WorkspaceItem.document(title: $0) }
    let width = 260.0, height = 380.0
    let proof = HStack(alignment: .top, spacing: 30) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        let geometry = WorkspaceItemGeometry.document(index.isMultiple(of: 2) ? .a4 : .letter)
        self.cover(item: item, geometry: geometry, model: model)
          .background { WorkspaceItemShadow(geometry: geometry) }
          .scaleEffect(width / geometry.width, anchor: .topLeading)
          .frame(width: width, height: height, alignment: .topLeading)
      }
    }.padding(36).background(Color(red: 0.925, green: 0.928, blue: 0.915))
    let size = CGSize(width: 4 * width + 3 * 30 + 72, height: height + 72)
    let image = try attachRendering(proof, size: size, name: "document-title-pages")
    let sx = Double(image.pixelsWide) / size.width, sy = Double(image.pixelsHigh) / size.height
    for (index, item) in items.enumerated() {
      let geometry = WorkspaceItemGeometry.document(index.isMultiple(of: 2) ? .a4 : .letter)
      let x = 36 + Double(index) * (width + 30), paperHeight = geometry.height * width / geometry.width
      let material = WorkspaceCoverRaster.material(item: item, geometry: geometry)
      XCTAssertEqual(geometry.paperSize, index.isMultiple(of: 2) ? .a4 : .letter)
      XCTAssertEqual(Double(material.width) / Double(material.height), geometry.width / geometry.height, accuracy: 0.002)
      var titlePixels = 0
      for py in Int((36 + paperHeight * 0.28) * sy)..<Int((36 + paperHeight * 0.60) * sy) {
        for px in Int((x + width * 0.13) * sx)..<Int((x + width * 0.87) * sx) {
          let color = try XCTUnwrap(image.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
          if printedInk(color) { titlePixels += 1 }
        }
      }
      // The maximum-length name may ellipsize after six readable lines rather
      // than shrinking into microtext. Its visible ink still must be substantial.
      XCTAssertGreaterThan(titlePixels, Int(Double(min(item.title.count, 100) * 4) * sx * sy),
        "The native title page must show its short or long title, not only blank paper")
    }
  }

  @MainActor
  func testClosedCoverHasNoPaperOutsideItsContour() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let cases: [(WorkspaceItem, WorkspaceItemGeometry)] = [
      (.notebook(title: "Тетрадь", pageIDs: [UUID()]), .notebook),
      (.document(title: "A4"), .document(.a4)),
      (.document(title: "Letter"), .document(.letter)),
    ]
    for (item, geometry) in cases {
      let scale = 0.5, padding = 12.0
      let width = geometry.width * scale, height = geometry.height * scale
      let size = CGSize(width: width + padding * 2, height: height + padding * 2)
      let proof = cover(item: item, geometry: geometry, model: model)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: width, height: height, alignment: .topLeading)
        .padding(padding).background(Color.black)
      let image = try attachRendering(proof, size: size, name: "clean-cover-contour-\(item.title)")
      let sx = Double(image.pixelsWide) / size.width, sy = Double(image.pixelsHigh) / size.height
      // One point beyond the body excludes its antialiasing. Only the separately
      // rendered shadow may extend here, never decorative copies of the paper.
      for point in [CGPoint(x: padding + width / 2, y: padding + height + 1),
        CGPoint(x: padding + width + 1, y: padding + height / 2)] {
        let color = try XCTUnwrap(image.colorAt(x: Int(point.x * sx), y: Int(point.y * sy))?.usingColorSpace(.sRGB))
        XCTAssertLessThan(max(color.redComponent, color.greenComponent, color.blueComponent), 0.02,
          "The closed cover must not expose paper beyond its bottom or right edge")
      }
    }
  }

  private func printedInk(_ color: NSColor) -> Bool {
    // Printed hues are not black. Count their antialiased stems by brightness,
    // below every paper tone, rather than requiring all RGB channels < 0.4.
    0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent < 0.60
  }

  @MainActor
  func testDocumentModelRestoresThePaperFitAfterWindowRotation() async throws {
    for paper in DocumentPaperSize.allCases {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let store = NotebookStore(root: root)
      let model = NotebookAppModel(store: store, startsNearbySync: false)
      let sizes = [PageSize(width: 1_366, height: 1_024), NotebookAppModel.defaultPageSize]
      let restoredModels = sizes.map { _ in NotebookAppModel(store: store, startsNearbySync: false) }
      let models = [model] + restoredModels
      addTeardownBlock { @MainActor in
        var allStopped = true
        for owner in models {
          let stopped = await owner.shutdown()
          allStopped = stopped && allStopped
        }
        XCTAssertTrue(allStopped, "Every restored model must drain before removing their shared store")
        guard allStopped else { return }
        try FileManager.default.removeItem(at: root)
      }
      await model.start(pageSize: NotebookAppModel.defaultPageSize)
      let id = try XCTUnwrap(model.createDocument(at: .zero, paperSize: paper))
      let geometry = WorkspaceItemGeometry.document(paper)
      let portrait = SpatialPoint(x: 834, y: 1_194)
      model.updatePresence(SessionPresence(mode: .document,
        camera: SpatialCamera(scale: geometry.fitScale(viewport: portrait)),
        viewport: portrait, focusedItemID: id, openProgress: 1), settled: true)
      let creationSaved = await model.shutdown()
      XCTAssertTrue(creationSaved, model.persistenceFailure ?? "")
      guard creationSaved else { return }
      for (size, restored) in zip(sizes, restoredModels) {
        await restored.start(pageSize: size)
        XCTAssertEqual(restored.itemGeometry(id), geometry)
        let presence = try XCTUnwrap(restored.presence)
        XCTAssertEqual(presence.camera.scale, geometry.fitScale(viewport: SpatialPoint(x: size.width, y: size.height)), accuracy: 1e-12)
        let restoredSaved = await restored.shutdown()
        XCTAssertTrue(restoredSaved)
        guard restoredSaved else { return }
      }
    }
  }

  @MainActor
  private func cover(item: WorkspaceItem, geometry: WorkspaceItemGeometry, model: NotebookAppModel) -> some View {
    WorkspaceItemCoverView(item: item, boardID: model.presence!.boardID, geometry: geometry,
      spatialInkSurfaces: SpatialInkSurfaceRegistry(), elements: [],
      editingTextID: nil,
      portalOpenProgress: 0, portalViewport: geometry.size,
      onTap: { _, _ in },
       onTextEditingEnded: { _ in })
      .environment(model)
  }

  @MainActor
  private func attachRendering<V: View>(_ view: V, size: CGSize, name: String) throws -> NSBitmapImageRep {
    // ImageRenderer cannot render the cover's NSViewRepresentable ink owner.
    // Capture the installed native hierarchy, as the cover curl itself does.
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: image)
    let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
    // The immutable test result owns this rendering. A second fixed output
    // beside the source would replace another run's evidence on the UI actor.
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    return image
  }
}
