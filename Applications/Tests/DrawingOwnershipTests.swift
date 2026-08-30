import PencilKit
import NotebookCore
import XCTest
@testable import Notebook

final class DrawingOwnershipTests: XCTestCase {
  func testCoverInkRendersOnTheCoverOwnedSurface() throws {
    let actor = UUID()
    let coverID = UUID()
    var journal = SpatialInkJournal(
      stamp: VersionStamp(counter: 0, actor: actor)
    )
    let samples = [
      spatialSample(x: 80, y: 120, time: 0),
      spatialSample(x: 240, y: 220, time: 0.05),
    ]
    let action = journal.append(
      tool: .pen,
      spans: [SpatialInkSpan(surface: .cover(coverID), samples: samples)],
      actor: actor
    )
    XCTAssertNotNil(action)

    let drawing = SpatialInkDrawingComposer.drawing(
      for: .cover(coverID),
      in: journal
    )

    XCTAssertEqual(drawing.strokes.count, 1)
    XCTAssertGreaterThan(drawing.bounds.width, 100)
  }

  @MainActor
  func testFinishedSpatialStrokeSurvivesTheNextPencilDown() {
    let view = InkCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    let first = ActiveInkStroke(style: .standard)
    first.replaceMeasuredTail(
      from: 0,
      with: [point(x: 20, y: 20), point(x: 180, y: 80)]
    )
    view.displayActiveStroke(first)
    view.commitActiveSpatialAction()
    let committed = view.committedVertexCount
    XCTAssertGreaterThan(committed, 0)

    let second = ActiveInkStroke(style: .standard)
    second.replaceMeasuredTail(
      from: 0,
      with: [point(x: 40, y: 160), point(x: 200, y: 220)]
    )
    view.displayActiveStroke(second)
    view.clearActiveAction()

    XCTAssertEqual(view.committedVertexCount, committed)
  }

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

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
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

  private func spatialSample(
    x: Double,
    y: Double,
    time: Double
  ) -> SpatialInkSample {
    SpatialInkSample(
      point: SpatialPoint(x: x, y: y),
      timeOffset: time,
      width: 4,
      opacity: 1,
      force: 1,
      azimuth: 0,
      altitude: .pi / 2
    )
  }

}
