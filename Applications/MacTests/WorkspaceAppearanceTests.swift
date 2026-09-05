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
  func testCoverMaterialsKeepStableIdentityAndReadablePencil() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    var ids: [NotebookCoverPalette: UUID] = [:]
    for value in 1...200 {
      let id = UUID(uuidString: String(format: "7E7A4000-0000-4000-8000-%012d", value))!
      ids[NotebookCoverPalette(itemID: id)] = id
    }
    XCTAssertEqual(ids.count, NotebookCoverPalette.allCases.count)
    let titles = ["Мысли", "Наблюдения", "Черновик", "Исследование", "Заметки", "Замыслы"]
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
    try save(proof, size: CGSize(width: 908, height: height * 2 + 102), name: "notebook-materials")
  }

  @MainActor
  func testDocumentModelRestoresThePaperFitAfterWindowRotation() throws {
    for paper in DocumentPaperSize.allCases {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = NotebookStore(root: root)
      let model = NotebookAppModel(store: store, startsNearbySync: false)
      model.start(pageSize: NotebookAppModel.defaultPageSize)
      let id = try XCTUnwrap(model.createDocument(at: .zero, paperSize: paper))
      let geometry = WorkspaceItemGeometry.document(paper)
      let portrait = SpatialPoint(x: 834, y: 1_194)
      model.updatePresence(SessionPresence(mode: .document,
        camera: SpatialCamera(scale: geometry.fitScale(viewport: portrait)),
        viewport: portrait, focusedItemID: id, openProgress: 1), settled: true)
      for size in [PageSize(width: 1_366, height: 1_024), NotebookAppModel.defaultPageSize] {
        let restored = NotebookAppModel(store: store, startsNearbySync: false)
        restored.start(pageSize: size)
        XCTAssertEqual(restored.itemGeometry(id), geometry)
        let presence = try XCTUnwrap(restored.presence)
        XCTAssertEqual(presence.camera.scale, geometry.fitScale(viewport: SpatialPoint(x: size.width, y: size.height)), accuracy: 1e-12)
      }
    }
  }

  @MainActor
  private func cover(item: WorkspaceItem, geometry: WorkspaceItemGeometry, model: NotebookAppModel) -> some View {
    WorkspaceItemCoverView(item: item, geometry: geometry,
      spatialInkSurfaces: SpatialInkSurfaceRegistry(), elements: [],
      editingTextID: nil, isElementEditingEnabled: false, rendersSettledSnapshot: true,
      portalOpenProgress: 0, portalViewport: geometry.size,
      onTap: { _, _ in }, onLiftChanged: { _ in }, onTranslationChanged: { _ in },
      onTranslationEnded: { _ in }, onTextEditingEnded: { _ in }, onElementSelected: {})
      .environment(model)
  }

  @MainActor
  private func save<V: View>(_ view: V, size: CGSize, name: String) throws {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.proposedSize = ProposedViewSize(size)
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.cgImage)
    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/material-proof", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try data.write(to: root.appendingPathComponent("\(name).png"), options: .atomic)
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
