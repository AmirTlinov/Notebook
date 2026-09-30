import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentPacketAdmissionTests: XCTestCase {
  func testAcceptedProgramPathsPublishIncrementallyAndKeepInstanceIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-packages-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try store.prepare()
    let shared = DocumentTestFiles.program(id: "shared", html: "<button>Own state</button>", height: 80)
    let third = DocumentTestFiles.program(id: "third", html: "<output>Independent package</output>", height: 80)
    let sourceText = #"""
      \documentclass{article}
      \usepackage{notebook}
      \begin{document}
      \NotebookInteractive[id=first,width=100bp,height=50bp]{programs/shared}
      \NotebookInteractive[id=second,width=100bp,height=50bp]{programs/shared}
      \NotebookInteractive[id=third,width=100bp,height=50bp]{programs/third}
      \end{document}
      """#
    let document = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: sourceText)] + shared.files + third.files)
    let resources = SceneRenderResources(), source = DocumentSourceSnapshot(document, store: store)
    _ = try await source.printedSource(resources: resources)
    var publications: [Set<String>] = []
    source.onProgramsChanged = { [weak source] in publications.append(Set(source?.programs.map(\.id) ?? [])) }
    try await source.preparePrograms(on: [0])
    let first = try XCTUnwrap(source.program("first")), second = try XCTUnwrap(source.program("second"))
    XCTAssertEqual(first.package, second.package)
    XCTAssertEqual(first.sourceBasis, second.sourceBasis)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(try store.readProgramPackage(first.programPackage), first.package)
    XCTAssertEqual(publications.last, ["first", "second", "third"])
    XCTAssertTrue(publications.contains { !$0.isEmpty && $0.count < 3 }, "A ready source path publishes before the other descriptor batch completes")
    XCTAssertEqual(resources.activeWebSurfaceCount, 0, "Accepted descriptors cannot create a second execution path")
    let previous = source.programs
    try await source.preparePrograms(on: [0])
    XCTAssertEqual(source.programs, previous)
    XCTAssertEqual(publications.count, 2, "One publication for each accepted path; revisiting consumes the same source-owned material")
  }

  func testSharedLayoutRetainsItsAllocationUntilItsLastReaderLeaves() throws {
    let resources = SceneRenderResources(profile: .interactive)
    var reservation = try XCTUnwrap(resources.reserveDerivedBytes(4096, priority: .passive)) as RasterReservation?
    let geometry = WorkspaceItemGeometry.uncompiledDocument
    var layout: DocumentLayoutRecord? = try DocumentLayoutRecord(receipt: [
      "sourceKey": "source", "layoutScope": "source", "layoutCanonical": true, "anchors": [], "reading": [], "pageCount": 1,
      "pages": [["widthPoints": DocumentPaperLayout.uncompiled.widthPoints, "heightPoints": DocumentPaperLayout.uncompiled.heightPoints]],
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
