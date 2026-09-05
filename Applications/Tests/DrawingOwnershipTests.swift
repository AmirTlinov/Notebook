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

    let layers = SpatialInkComposer.localLayers(for: .cover(coverID), journal: journal)
    XCTAssertEqual(layers.count, 1)
    guard case .ink(let points, _) = layers[0] else { return XCTFail("Ожидалась ручка") }
    XCTAssertGreaterThan(points.last!.location.x - points.first!.location.x, 100)

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
      board: .board,
      journal: journal,
      camera: SpatialCamera(scale: 1),
      viewport: SpatialPoint(
        x: WorkspaceItemGeometry.notebook.width,
        y: WorkspaceItemGeometry.notebook.height
      )
    )
    XCTAssertTrue(boardLayers.isEmpty, "Холст доски не должен рисовать обложку")

    let registry = SpatialInkSurfaceRegistry()
    let boardView = InkCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    let coverView = InkCanvasView(
      frame: CGRect(
        x: 0,
        y: 0,
        width: WorkspaceItemGeometry.notebook.width,
        height: WorkspaceItemGeometry.notebook.height
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
  func testARepeatedModelSnapshotCannotReplaceANewerLocalDrawing() async throws {
    let base = PageInkDrawing(actions: [stroke(y: 20)])
    let pageID = UUID()
    let actorID = UUID()
    var counter: UInt64 = 0
    var page = PageDocument(id: pageID, size: .init(width: 834, height: 1194), actor: actorID, drawingData: try base.dataRepresentation())
    let delivered = expectation(description: "local drawing serialized")
    let coordinator = PencilCanvasView.Coordinator(
      inputGate: NotebookInputGate(),
      reserveAction: { _ in
        counter += 1
        return VersionStamp(counter: counter, actor: actorID)
      },
      commitAction: { action, _, stamp in
        let change = try! page.prepareInkChange(.append(action), stamp: stamp)
        _ = page.publishInkChange(change)
        delivered.fulfill()
        return change
      }
    )
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper)
    coordinator.apply(try base.dataRepresentation(), pageID: pageID, to: paper)

    coordinator.commit(stroke(y: 40), on: paper)
    coordinator.apply(try base.dataRepresentation(), pageID: pageID, to: paper)

    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(paper.touchView.accessibilityValue, "2 действий пера")
  }

  @MainActor
  func testFinishedErasersQueueWithoutHoldingTheNextPencilGesture() async throws {
    let base = PageInkDrawing(actions: [stroke(y: 20), stroke(y: 60)])
    let pageID = UUID()
    let actorID = UUID()
    var counter: UInt64 = 0
    var finalData = Data()
    var page = PageDocument(id: pageID, size: .init(width: 834, height: 1194), actor: actorID, drawingData: try base.dataRepresentation())
    let delivered = expectation(description: "both erasers serialized")
    delivered.expectedFulfillmentCount = 2
    let coordinator = PencilCanvasView.Coordinator(
      inputGate: NotebookInputGate(),
      reserveAction: { _ in
        counter += 1
        return VersionStamp(counter: counter, actor: actorID)
      },
      commitAction: { action, _, stamp in
        let change = try! page.prepareInkChange(.append(action), stamp: stamp)
        _ = page.publishInkChange(change)
        finalData = change.data
        delivered.fulfill()
        return change
      }
    )
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper)
    coordinator.apply(try base.dataRepresentation(), pageID: pageID, to: paper)

    let first = PKStrokePath(
      controlPoints: [
        point(x: 0, y: 20, width: 30),
        point(x: 110, y: 20, width: 30),
      ],
      creationDate: Date()
    )
    let second = PKStrokePath(
      controlPoints: [
        point(x: 0, y: 60, width: 30),
        point(x: 110, y: 60, width: 30),
      ],
      creationDate: Date()
    )

    coordinator.commit(PageInkAction(tool: .eraser, points: Array(first)), on: paper)
    coordinator.commit(PageInkAction(tool: .eraser, points: Array(second)), on: paper)
    XCTAssertEqual(
      counter,
      2,
      "Pencil-up must enqueue the next action before durable work finishes"
    )

    await fulfillment(of: [delivered], timeout: 2)
    let drawing = try PageInkDrawing.decode(finalData)
    XCTAssertEqual(drawing.actions.map(\.tool), [.pen, .pen, .eraser, .eraser])
  }

  @MainActor
  func testPrewarmedSheetCannotReplaceTheCurrentPageFinisher() {
    let gate = NotebookInputGate()
    let current = UUID()
    let neighbour = UUID()
    var events: [String] = []

    gate.registerPageFinisher(source: current) { _, completion in
      events.append("current")
      completion()
    }
    gate.setCurrentPageSource(current, isCurrent: true)
    gate.registerPageFinisher(source: neighbour) { _, completion in
      events.append("neighbour")
      completion()
    }
    gate.setCurrentPageSource(neighbour, isCurrent: false)

    gate.performAfterPageInput { events.append("action") }
    XCTAssertEqual(events, ["current", "action"])

    gate.setCurrentPageSource(current, isCurrent: false)
    gate.setCurrentPageSource(neighbour, isCurrent: true)
    gate.performAfterPageInput { events.append("next action") }
    XCTAssertEqual(
      events,
      ["current", "action", "neighbour", "next action"]
    )
  }

  @MainActor
  func testReservedLocalContactMergesWithNewerRemoteInkAndUndoesOnlyItself() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let pageID = try XCTUnwrap(model.activePage?.id)
    let localStamp = try XCTUnwrap(model.reserveDrawingAction(pageID: pageID))
    let localStroke = stroke(y: 40)

    var remote = try XCTUnwrap(model.activePage)
    let remoteActor = UUID()
    let firstRemote = stroke(y: 60), secondRemote = stroke(y: 80)
    let remoteDrawing = PageInkDrawing().appending(firstRemote)
    remote.replaceDrawing(try remoteDrawing.dataRepresentation(), actor: remoteActor)
    let remoteData = try remoteDrawing.appending(secondRemote).dataRepresentation()
    remote.replaceDrawing(remoteData, actor: remoteActor)
    try store.savePage(remote)
    model.reloadExternalChanges()

    let accepted = await model.commitDrawingAction(
      localStroke,
      pageID: pageID,
      stamp: localStamp
    )

    let merged = try XCTUnwrap(accepted).drawing
    XCTAssertEqual(Set(merged.activeActions.map(\.id)), [localStroke.id, firstRemote.id, secondRemote.id])
    XCTAssertEqual(model.activePage?.drawingData, accepted?.data)
    XCTAssertGreaterThan(try XCTUnwrap(model.activePage?.drawingStamp), remote.drawingStamp)
    await model.undoLastDrawingAction()
    let undone = try PageInkDrawing.decode(XCTUnwrap(model.activePage?.drawingData))
    XCTAssertEqual(undone.activeActions.map(\.id), [firstRemote.id, secondRemote.id])
    XCTAssertEqual(undone.actions.first { $0.id == localStroke.id }?.isActive, false)
  }

  private func stroke(y: CGFloat) -> PageInkAction {
    PageInkAction(tool: .pen, points: [point(x: 10, y: y), point(x: 100, y: y)])
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
