import PencilKit
import NotebookCore
import XCTest
@testable import Notebook

final class DrawingOwnershipTests: XCTestCase {
  func testCoverInkKeepsItsSurfaceIdentityInTheSpatialScene() throws {
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
  func testSpatialSceneReplaysTheExactPenAndEraserGeometry() {
    let points = [
      point(x: 20, y: 20, width: PenStyle.standard.width),
      point(x: 180, y: 80, width: PenStyle.standard.width),
    ]
    let view = InkCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    let active = ActiveInkStroke(style: .standard)
    active.replaceMeasuredTail(from: 0, with: points)
    view.displayActiveStroke(active)
    view.commitActiveSpatialAction()
    let liveVertexCount = view.committedVertexCount

    view.applySpatial([
      .ink(points: points, color: .black),
      .erase(points: [
        point(x: 70, y: 45, width: 30),
        point(x: 130, y: 65, width: 30),
      ]),
    ])

    XCTAssertGreaterThan(liveVertexCount, 0)
    XCTAssertGreaterThan(view.committedEraserVertexCount, 0)
    view.applySpatial([.ink(points: points, color: .black)])
    XCTAssertEqual(view.committedVertexCount, liveVertexCount)
  }

  @MainActor
  func testCoverEraserReachesTheSameVisibleSpatialSceneAsCoverInk() {
    let actor = UUID()
    let coverID = UUID()
    var journal = SpatialInkJournal(
      stamp: VersionStamp(counter: 0, actor: actor)
    )
    let ink = [
      spatialSample(x: 80, y: 120, time: 0, width: 8),
      spatialSample(x: 240, y: 120, time: 0.05, width: 8),
    ]
    let eraser = [
      spatialSample(x: 60, y: 120, time: 0, width: 40),
      spatialSample(x: 260, y: 120, time: 0.05, width: 40),
    ]
    XCTAssertNotNil(journal.append(
      tool: .pen,
      spans: [SpatialInkSpan(surface: .cover(coverID), samples: ink)],
      actor: actor
    ))
    XCTAssertNotNil(journal.append(
      tool: .eraser,
      spans: [SpatialInkSpan(surface: .cover(coverID), samples: eraser)],
      actor: actor
    ))
    let persistedCover = SpatialInkDrawingComposer.drawing(
      for: .cover(coverID),
      in: journal
    )
    XCTAssertTrue(
      persistedCover.strokes.flatMap(InkStrokeGeometry.visibleRuns).isEmpty,
      "Тот же ластик должен убрать линию и в сохранённом представлении Mac"
    )

    let layers = SpatialInkComposer.localLayers(
      for: .cover(coverID),
      journal: journal
    )

    XCTAssertEqual(layers.count, 2)
    guard case .ink(let inkPoints, _) = layers[0],
      case .erase(let eraserPoints) = layers[1]
    else {
      return XCTFail("Обложка должна послать ручку и ластик в один Metal-порядок")
    }
    XCTAssertEqual(inkPoints.map(\.location.x), [80, 240])
    XCTAssertEqual(eraserPoints.map(\.location.x), [60, 260])

    let boardLayers = SpatialInkComposer.boardLayers(
      journal: journal,
      camera: SpatialCamera(scale: 1),
      viewport: SpatialPoint(
        x: NotebookGeometry.width,
        y: NotebookGeometry.height
      )
    )
    XCTAssertTrue(boardLayers.isEmpty, "Холст доски не должен рисовать обложку")

    let registry = SpatialInkSurfaceRegistry()
    let boardView = InkCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    let coverView = InkCanvasView(
      frame: CGRect(
        x: 0,
        y: 0,
        width: NotebookGeometry.width,
        height: NotebookGeometry.height
      )
    )
    registry.register(boardView, for: .board)
    registry.register(coverView, for: .cover(coverID))
    registry.applyStable(layers, to: .cover(coverID))

    XCTAssertEqual(boardView.committedVertexCount, 0)
    XCTAssertGreaterThan(coverView.committedEraserVertexCount, 0)
  }

  @MainActor
  func testStableReplayWaitsForTheActiveSurfaceGesture() {
    let cover = SurfaceID.cover(UUID())
    let registry = SpatialInkSurfaceRegistry()
    let view = InkCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    let first = [point(x: 20, y: 30), point(x: 180, y: 70)]
    registry.register(view, for: cover)
    registry.applyStable([.ink(points: first, color: .black)], to: cover)
    let stableCount = view.committedVertexCount

    registry.beginAction(on: cover)
    registry.applyStable([], to: cover)
    let active = ActiveInkStroke(style: .standard)
    active.replaceMeasuredTail(
      from: 0,
      with: [point(x: 40, y: 130), point(x: 220, y: 170)]
    )
    view.displayActiveStroke(active)
    view.commitActiveSpatialAction()
    let locallyCommittedCount = view.committedVertexCount
    registry.finishAction(on: cover, keepingCommittedMesh: true)

    XCTAssertGreaterThan(stableCount, 0)
    XCTAssertGreaterThan(locallyCommittedCount, stableCount)
    XCTAssertEqual(view.committedVertexCount, locallyCommittedCount)
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

  private func point(
    x: CGFloat,
    y: CGFloat,
    width: Double = 4
  ) -> PKStrokePoint {
    PKStrokePoint(
      location: CGPoint(x: x, y: y),
      timeOffset: 0,
      size: CGSize(width: width, height: width),
      opacity: 1,
      force: 1,
      azimuth: 0,
      altitude: .pi / 2
    )
  }

  private func spatialSample(
    x: Double,
    y: Double,
    time: Double,
    width: Double = 4
  ) -> SpatialInkSample {
    SpatialInkSample(
      point: SpatialPoint(x: x, y: y),
      timeOffset: time,
      width: width,
      opacity: 1,
      force: 1,
      azimuth: 0,
      altitude: .pi / 2
    )
  }

}
