import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentLayoutIndexTests: XCTestCase {
  func testProgramViewportLookupStaysAddressedAcross100000FragmentsAndSourceRebinding() throws {
    let count = 100_000, programCount = 1_000
    let paper = DocumentPaperLayout(widthPoints: 720, heightPoints: 400)
    let ids = (0..<programCount).map { "program-\($0)" }
    let regions: [DocumentBlockRegion] = (0..<count).map { index in
      .init(kind: index == count - 1 ? .file : .program, id: ids[index % programCount], pageIndex: index / 100,
        frame: .init(x: 0, y: 0, width: index < programCount ? 100.0 + Double(index % 3) : 200,
          height: 10), sourceOffset: Double(index / programCount) * 10)
    }
    let layout = try DocumentLayoutFixture.make(pages: Array(repeating: paper, count: count / 100), regions: regions)
    for (index, id) in ids.enumerated() {
      XCTAssertEqual(layout.programSize(id), .init(width: 100 + Double(index % 3), height: index == programCount - 1 ? 990 : 1_000))
    }
    XCTAssertNil(layout.programSize("missing"))
    XCTAssertEqual(layout.programHeights(ids: [ids[0], ids[999], "missing"]), [ids[0]: 1_000, ids[999]: 990])
    let rebound = DocumentLayoutRecord(rebinding: layout, buildID: "new-source-identity")
    XCTAssertEqual(rebound.programSize(ids[999]), layout.programSize(ids[999]))

    // Compare the replaced per-lookup scan with the actual warm owner lookup.
    // The result is a native lookup budget, not a frame-rate measurement.
    let probes = (0..<1_024).map { ids[($0 * 37) % programCount] }
    var scanned: [Double] = [], indexed: [Double] = []
    for _ in 0..<3 {
      var expected = 0.0, actual = 0.0
      var start = ContinuousClock.now
      for id in probes {
        let fragments = layout.regions.filter { $0.kind == .program && $0.id == id }
        expected += fragments.map { $0.sourceOffset + $0.frame.height }.max() ?? 0
      }
      scanned.append(seconds(start.duration(to: .now)))
      start = .now
      for id in probes { actual += Double(rebound.programSize(id)?.height ?? 0) }
      indexed.append(seconds(start.duration(to: .now)))
      XCTAssertEqual(actual, expected)
    }
    let baseline = scanned.sorted()[1], addressed = indexed.sorted()[1]
    XCTAssertLessThan(addressed, baseline / 10, "Warm lookup must not rescan unrelated document fragments")
    print("NOTEBOOK_PROGRAM_LAYOUT_INDEX fragments=\(count) lookups=\(probes.count) scan_ms=\(baseline * 1_000) indexed_ms=\(addressed * 1_000)")
  }

  private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
