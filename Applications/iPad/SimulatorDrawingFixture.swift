#if DEBUG && targetEnvironment(simulator)
  import Foundation
  import PencilKit
  import NotebookCore

  @MainActor
  enum SimulatorDrawingFixture {
    static let launchArgument = "--notebook-drawing-responsiveness-fixture"
    static let fingerGestureArgument = "--notebook-simulator-finger-gestures"
    static let coverArgument = "--notebook-nearby-cover-fixture"
    static let stackArgument = "--notebook-stacked-page-fixture"
    static let lowerStackArgument = "--notebook-stacked-lower-page-fixture"
    static let stackBoardArgument = "--notebook-stacked-board-fixture"

    static var isRequested: Bool {
      ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func makeModel() -> NotebookAppModel {
      let fileManager = FileManager.default
      let startsAtCover = ProcessInfo.processInfo.arguments.contains(
        coverArgument
      )
      let startsInStack = ProcessInfo.processInfo.arguments.contains(
        stackArgument
      ) || ProcessInfo.processInfo.arguments.contains(lowerStackArgument)
        || ProcessInfo.processInfo.arguments.contains(stackBoardArgument)
      let selectsLowerStackMember = ProcessInfo.processInfo.arguments.contains(
        lowerStackArgument
      )
      let startsOnStackBoard = ProcessInfo.processInfo.arguments.contains(
        stackBoardArgument
      )
      let fixtureName: String
      if startsInStack {
        fixtureName = startsOnStackBoard
          ? "StackedBoard"
          : (selectsLowerStackMember
            ? "StackedLowerPage"
            : "StackedUpperPage")
      } else if startsAtCover {
        fixtureName = "NearbyCoverTransition"
      } else if ProcessInfo.processInfo.arguments.contains(
        fingerGestureArgument
      ) {
        fixtureName = "SpatialTransition"
      } else {
        fixtureName = "DrawingResponsiveness"
      }
      let root = fileManager.temporaryDirectory
        .appendingPathComponent("NotebookUITests", isDirectory: true)
        .appendingPathComponent(fixtureName, isDirectory: true)
      do {
        if fileManager.fileExists(atPath: root.path) {
          try fileManager.removeItem(at: root)
        }

        let store = NotebookStore(root: root)
        let actor = UUID(
          uuidString: "7E7A1000-0000-4000-8000-000000000001"
        )!
        let notebookID = UUID(
          uuidString: "7E7A1000-0000-4000-8000-000000000002"
        )!
        let pageID = UUID(
          uuidString: "7E7A1000-0000-4000-8000-000000000003"
        )!
        let size = NotebookAppModel.defaultPageSize
        let initial = WorkspaceIndex.initial(
          actor: actor,
          pageSize: size,
          notebookID: notebookID,
          pageID: pageID
        )
        var index = initial.index
        let page = PageDocument(
          id: pageID,
          size: size,
          actor: actor,
          drawingData: denseDrawing(size: size).dataRepresentation()
        )
        try store.savePage(page)
        if startsInStack {
          let upperNotebookID = UUID(
            uuidString: "7E7A1000-0000-4000-8000-000000000004"
          )!
          let upperPageID = UUID(
            uuidString: "7E7A1000-0000-4000-8000-000000000005"
          )!
          guard let upper = index.createNotebook(
            title: "Notebook 2",
            actor: actor,
            pageSize: size,
            notebookID: upperNotebookID,
            pageID: upperPageID
          ) else {
            fatalError("Не удалось создать верхнюю тетрадь проверки")
          }
          if selectsLowerStackMember {
            _ = index.selectNotebook(notebookID, actor: actor)
          }
          var board = BoardDocument.initial(
            notebookIDs: [notebookID, upperNotebookID],
            actor: actor
          )
          guard board.createStack(
            moving: upperNotebookID,
            onto: notebookID,
            actor: actor
          ) != nil else {
            fatalError("Не удалось создать стопку проверки")
          }
          let selectedNotebookID = selectsLowerStackMember
            ? notebookID
            : upperNotebookID
          guard let focusedCenter = board.focusedCenter(
            of: selectedNotebookID
          ), let stackCenter = board.stack(
            containing: selectedNotebookID
          )?.center else {
            fatalError("Не удалось получить центр тетради в стопке")
          }
          let viewport = SpatialPoint(x: size.width, y: size.height)
          try store.savePage(upper.page)
          try store.saveBoard(
            board,
            notebookIDs: Set([notebookID, upperNotebookID])
          )
          try store.savePresence(
            startsOnStackBoard
              ? SessionPresence(
                mode: .board,
                camera: SpatialCamera(
                  center: stackCenter,
                  scale: NotebookPresentation.coverScale(viewport: viewport)
                ),
                viewport: viewport
              )
              : SessionPresence(
                mode: .page,
                camera: SpatialCamera(
                  center: focusedCenter,
                  scale: NotebookPresentation.fitScale(viewport: viewport)
                ),
                viewport: viewport,
                focusedNotebookID: selectedNotebookID,
                openProgress: 1
              )
          )
        } else if startsAtCover {
          let board = BoardDocument.initial(
            notebookIDs: [notebookID],
            actor: actor
          )
          let center = board.placement(of: notebookID)?.center
            ?? WorldPoint(x: 0, y: 0)
          let viewport = SpatialPoint(x: size.width, y: size.height)
          try store.saveBoard(board, notebookIDs: Set([notebookID]))
          try store.savePresence(
            SessionPresence(
              mode: .cover,
              camera: SpatialCamera(
                center: center,
                scale: NotebookPresentation.coverScale(viewport: viewport)
              ),
              viewport: viewport,
              focusedNotebookID: notebookID,
              openProgress: 0
            )
          )
        }
        try store.saveIndex(index)
        return NotebookAppModel(store: store, startsNearbySync: false)
      } catch {
        fatalError("Не удалось создать лист проверки инструментов: \(error)")
      }
    }

    private static func denseDrawing(size: PageSize) -> PKDrawing {
      let strokeCount = 80
      let pointsPerStroke = 64
      let horizontalInset = 80.0
      let verticalInset = 80.0
      let usableWidth = size.width - (horizontalInset * 2)
      let usableHeight = size.height - (verticalInset * 2)

      let strokes = (0..<strokeCount).map { strokeIndex in
        let xProgress = Double(strokeIndex) / Double(strokeCount - 1)
        let baseX = horizontalInset + (usableWidth * xProgress)
        let points = (0..<pointsPerStroke).map { pointIndex in
          let progress = Double(pointIndex) / Double(pointsPerStroke - 1)
          let wave = sin((progress * .pi * 6) + Double(strokeIndex)) * 3
          return PKStrokePoint(
            location: CGPoint(
              x: baseX + wave,
              y: verticalInset + (usableHeight * progress)
            ),
            timeOffset: Double(pointIndex) / 120,
            size: CGSize(width: 2.2, height: 2.2),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
          )
        }
        return PKStroke(
          ink: PKInk(.pen, color: .black),
          path: PKStrokePath(
            controlPoints: points,
            creationDate: Date(timeIntervalSince1970: Double(strokeIndex))
          ),
          randomSeed: UInt32(strokeIndex)
        )
      }
      return PKDrawing(strokes: strokes)
    }
  }
#endif
