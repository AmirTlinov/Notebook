import NotebookCore
import XCTest
@testable import Notebook

@MainActor
enum DocumentLayoutFixture {
  static func make(pages: [DocumentPaperLayout] = [.uncompiled], regions: [DocumentBlockRegion] = [],
    reading: [DocumentReadingIndex.Segment] = [], anchors: [String: Int] = [:],
    reservation: RasterReservation? = nil) throws -> DocumentLayoutRecord {
    let files = Set(regions.filter { $0.kind == .file }.map(\.id)).union(reading.map(\.fileID))
    let prepared = try DocumentPreparedLayout(pages: pages, regions: regions, fileIDs: files,
      reading: reading, anchors: anchors)
    let allocation = try reservation ?? XCTUnwrap(SceneRenderResources.shared.reserveDerivedBytes(
      prepared.byteCount, priority: .passive))
    return DocumentLayoutRecord(prepared: prepared, buildID: "fixture", allocation: .init(allocation))
  }
}
