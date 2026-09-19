#if os(macOS)
import Foundation
import CoreGraphics
import NotebookCore

struct DocumentPDFVector: Sendable {
  let pdf: Data
  let frame: CGRect // Full authored region in physical PDF points, top-left.
  let clip: CGRect  // The existing page fragment, never a new pagination.
}
@MainActor struct DocumentPDFVectors {
  let values: [DocumentPDFVector]
  let storage: RasterReservation?
}

extension DocumentWebCoordinator {
  /// Read optional replacement regions from the same stopped model that just
  /// produced the canonical raster. Unsupported authors return an empty list;
  /// declared but invalid vectors fail the job, never silently become pixels.
  func exportPDFVectors(pointScale: Double) async throws -> DocumentPDFVectors {
    struct Layer: Decodable { let svg: String; let frame: PageRect }
    guard exportSnapshotID != nil, let before = payload, !isInvalidated,
      let webView, let layout = before.source.layout else { throw CancellationError() }
    let regions = layout.regions(on: before.pageIndex)
    var values: [DocumentPDFVector] = [], storage: RasterReservation?, bytes = 0
    do {
      for block in before.blocks where block.kind == .interactive && regions.contains(where: { $0.id == block.id }) {
        let layers = try await NotebookProgramBridge.lifecycle("exportProgram", controller: "notebookRenderer",
          argument: .object(["format": .string("pdf"), "blockID": .string(block.id),
            "state": before.states[block.id] ?? block.initialState]), in: webView).decode([Layer].self)
        guard !isInvalidated, payload?.renderToken == before.renderToken else { throw CancellationError() }
        let fragments = regions.filter { $0.id == block.id }
        guard layers.count <= 16, let fragment = fragments.first else { throw SceneRenderError.resourceLimit }
        var preceding: [CGRect] = []
        for layer in layers {
          let r = layer.frame, rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
          guard [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite), r.x >= 0, r.y >= 0, r.width > 0, r.height > 0,
            r.x+r.width <= fragment.frame.width+0.01, r.y+r.height <= block.height+0.01,
            preceding.allSatisfy({ !$0.intersects(rect) }) else {
            throw CollaborationError("invalid_export_vector", "Векторные области должны быть непересекающимися и находиться внутри программы.")
          }
          preceding.append(rect)
          let svg = Data(layer.svg.utf8); try NotebookExportSVG.validate(svg)
          if storage == nil {
            guard let reserved = resourceOwner.reserveDerivedBytes(8*1024*1024, priority: .passive) else { throw SceneRenderError.resourceLimit }
            storage = reserved
          }
          let pdf = try await DocumentCanonicalPrint.store.vectorPDF(svg)
          bytes += pdf.count
          guard bytes <= 8*1024*1024 else { throw SceneRenderError.resourceLimit }
          for fragment in fragments {
            let f = fragment.frame
            let frame = CGRect(x: (f.x+r.x)*pointScale, y: (f.y+r.y-fragment.sourceOffset)*pointScale,
              width: r.width*pointScale, height: r.height*pointScale)
            let clip = CGRect(x: f.x*pointScale, y: f.y*pointScale, width: f.width*pointScale, height: f.height*pointScale)
            if frame.intersects(clip) { values.append(.init(pdf: pdf, frame: frame, clip: clip)) }
          }
          guard values.count <= 128 else { throw SceneRenderError.resourceLimit }
        }
      }
      try Task.checkCancellation()
      return .init(values: values, storage: storage)
    } catch { storage?.release(); throw error }
  }
}
#endif
