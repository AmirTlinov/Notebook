import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentPacketAdmissionTests: XCTestCase {
  func testDescriptorBindsSourcePageAndPositiveBoundedUTF8Count() throws {
    func descriptor(key: String = "source", page: Any = 2, bytes: Any = 123) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject:
        ["sourceKey": key, "pageIndex": page, "utf8Bytes": bytes]), as: UTF8.self)
    }
    let valid = try DocumentPacketDescriptor.decode(descriptor(), sourceKey: "source", pageIndex: 2, maximumBytes: 123)
    XCTAssertEqual(valid.utf8Bytes, 123)
    _ = try DocumentPacketDescriptor.decode(descriptor(page: NSNull()), sourceKey: "source", pageIndex: nil, maximumBytes: 123)
    for raw in try [descriptor(key: "other"), descriptor(page: 1), descriptor(page: NSNull()),
      descriptor(bytes: 0), descriptor(bytes: -1), descriptor(bytes: 124), descriptor(bytes: 1.5),
      descriptor(bytes: String(repeating: "9", count: 600))] {
      XCTAssertThrowsError(try DocumentPacketDescriptor.decode(raw, sourceKey: "source", pageIndex: 2, maximumBytes: 123))
    }
  }

  func testSharedLayoutRetainsItsAllocationUntilItsLastReaderLeaves() throws {
    let resources = SceneRenderResources(profile: .interactive)
    var reservation = try XCTUnwrap(resources.reserveDerivedBytes(4096, priority: .passive)) as RasterReservation?
    let geometry = WorkspaceItemGeometry.document(.a4)
    var layout: DocumentLayoutRecord? = try DocumentLayoutRecord(receipt: [
      "sourceKey": "source", "layoutScope": "source", "layoutCanonical": true, "anchors": [], "pageCount": 1,
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
