import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentPacketAdmissionTests: XCTestCase {
  func testSharedLayoutRetainsItsAllocationUntilItsLastReaderLeaves() throws {
    let resources = SceneRenderResources(profile: .interactive)
    var reservation = try XCTUnwrap(resources.reserveDerivedBytes(4096, priority: .passive)) as RasterReservation?
    let geometry = WorkspaceItemGeometry.document(.a4)
    var layout: DocumentLayoutRecord? = try DocumentLayoutRecord(receipt: [
      "sourceKey": "source", "layoutScope": "source", "layoutCanonical": true, "anchors": [], "reading": [], "pageCount": 1,
      "width": geometry.width, "height": geometry.height, "regions": []
    ] as NSDictionary, sourceKey: "source", blockIDs: [], geometry: geometry, reservation: reservation)
    weak let allocation = reservation
    reservation = nil
    var reader = layout
    layout = nil
    XCTAssertEqual(reader?.pageCount, 1)
    XCTAssertNotNil(allocation)
    XCTAssertEqual(resources.reservedBytes, 4096)
    reader = nil
    XCTAssertNil(allocation)
    XCTAssertEqual(resources.reservedBytes, 0)
  }
}
