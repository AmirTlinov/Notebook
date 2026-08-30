import PencilKit
import TetradCore
import XCTest
@testable import Tetrad

final class DrawingOwnershipTests: XCTestCase {
  @MainActor
  func testARepeatedModelSnapshotCannotReplaceANewerLocalDrawing() async {
    let base = PKDrawing(strokes: [stroke(y: 20)])
    let local = PKDrawing(strokes: [stroke(y: 20), stroke(y: 40)])
    let pageID = UUID()
    let actorID = UUID()
    var counter: UInt64 = 0
    let delivered = expectation(description: "local drawing serialized")
    let coordinator = PencilCanvasView.Coordinator(
      pageInputGate: PageInputGate(),
      reserveAction: { _ in
        counter += 1
        return VersionStamp(counter: counter, actor: actorID)
      },
      commitAction: { data, _, _, _ in
        delivered.fulfill()
        return data
      }
    )
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper)
    coordinator.apply(base.dataRepresentation(), pageID: pageID, to: paper)

    paper.apply(local)
    paper.touchView.onDrawingChange?(local)
    coordinator.apply(base.dataRepresentation(), pageID: pageID, to: paper)

    XCTAssertEqual(paper.touchView.accessibilityValue, "2 штрихов")
    await fulfillment(of: [delivered], timeout: 2)
  }

  @MainActor
  func testRemoteDrawingWinsWhenItIsNewerThanAReservedLocalAction() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = TetradStore(root: root)
    let model = TetradAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let pageID = try XCTUnwrap(model.activePage?.id)
    let localStamp = try XCTUnwrap(model.reserveDrawingAction(pageID: pageID))
    let localData = PKDrawing(strokes: [stroke(y: 40)]).dataRepresentation()

    var remote = try XCTUnwrap(model.activePage)
    let remoteActor = UUID()
    remote.replaceDrawing(
      PKDrawing(strokes: [stroke(y: 60)]).dataRepresentation(),
      actor: remoteActor
    )
    let remoteData = PKDrawing(strokes: [stroke(y: 80)]).dataRepresentation()
    remote.replaceDrawing(remoteData, actor: remoteActor)
    try store.savePage(remote)
    model.reloadExternalChanges()

    let accepted = model.commitDrawingAction(
      localData,
      replacing: Data(),
      pageID: pageID,
      stamp: localStamp
    )

    XCTAssertEqual(accepted, remoteData)
    XCTAssertEqual(model.activePage?.drawingData, remoteData)
  }

  private func stroke(y: CGFloat) -> PKStroke {
    let points = [
      point(x: 10, y: y),
      point(x: 100, y: y),
    ]
    return PKStroke(
      ink: PKInk(.monoline, color: .black),
      path: PKStrokePath(controlPoints: points, creationDate: Date())
    )
  }

  private func point(x: CGFloat, y: CGFloat) -> PKStrokePoint {
    PKStrokePoint(
      location: CGPoint(x: x, y: y),
      timeOffset: 0,
      size: CGSize(width: 4, height: 4),
      opacity: 1,
      force: 1,
      azimuth: 0,
      altitude: .pi / 2
    )
  }

}
