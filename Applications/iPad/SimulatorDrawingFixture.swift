#if DEBUG && targetEnvironment(simulator)
  import Foundation
  import PencilKit
  import NotebookCore

  @MainActor
  enum SimulatorDrawingFixture {
    static let launchArgument = "--notebook-drawing-responsiveness-fixture"
    static let fingerGestureArgument = "--notebook-simulator-finger-gestures"
    static let mixedInputArgument = "--notebook-simulator-mixed-input"
    static let coverArgument = "--notebook-nearby-cover-fixture"
    static let coverEraserArgument = "--notebook-cover-eraser-fixture"
    static let offCenterCoverArgument = "--notebook-off-center-cover-fixture"
    static let stackArgument = "--notebook-stacked-page-fixture"
    static let lowerStackArgument = "--notebook-stacked-lower-page-fixture"
    static let stackBoardArgument = "--notebook-stacked-board-fixture"
    static let documentArgument = "--notebook-document-runtime-fixture"

    static var isRequested: Bool {
      ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func makeModel() -> NotebookAppModel {
      let fileManager = FileManager.default
      let startsAtCover = ProcessInfo.processInfo.arguments.contains(
        coverArgument
      ) || ProcessInfo.processInfo.arguments.contains(offCenterCoverArgument)
        || ProcessInfo.processInfo.arguments.contains(coverEraserArgument)
      let startsWithCoverEraser = ProcessInfo.processInfo.arguments.contains(
        coverEraserArgument
      )
      let startsOffCenterCover = ProcessInfo.processInfo.arguments.contains(
        offCenterCoverArgument
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
      let startsInDocument = ProcessInfo.processInfo.arguments.contains(
        documentArgument
      )
      let fixtureName: String
      if startsInDocument {
        fixtureName = "DocumentRuntime"
      } else if startsInStack {
        fixtureName = startsOnStackBoard
          ? "StackedBoard"
          : (selectsLowerStackMember
            ? "StackedLowerPage"
            : "StackedUpperPage")
      } else if startsAtCover {
        fixtureName = startsWithCoverEraser
          ? "CoverEraser"
          : (startsOffCenterCover
            ? "OffCenterCoverTransition"
            : "NearbyCoverTransition")
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
        let itemID = UUID(
          uuidString: "7E7A1000-0000-4000-8000-000000000002"
        )!
        let pageID = UUID(
          uuidString: "7E7A1000-0000-4000-8000-000000000003"
        )!
        let size = NotebookAppModel.defaultPageSize
        let initial = WorkspaceIndex.initial(
          actor: actor,
          pageSize: size,
          itemID: itemID,
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
        if startsInDocument {
          let documentID = UUID(
            uuidString: "7E7A1000-0000-4000-8000-000000000006"
          )!
          guard index.createDocument(
            title: "Живая математика",
            actor: actor,
            documentID: documentID
          ) != nil else {
            fatalError("Не удалось создать документ проверки")
          }
          let document = DocumentDocument(
            id: documentID,
            actor: actor,
            blocks: [
              .markdown(
                id: "introduction",
                source: "# Живая математика\n\nДокумент соединяет текст, формулы и управление."
              ),
              .latex(
                id: "equation",
                source: #"\begin{aligned} f(x) &= x^2 \\ f'(x) &= 2x \end{aligned}"#
              ),
              .interactive(
                id: "square",
                html: "<label for='x'>x = <output id='value'>3</output></label><input id='x' type='range' min='0' max='10' value='3'><p>x² = <strong id='square'>9</strong></p>",
                css: "body{font:22px -apple-system;padding:18px}input{width:100%}",
                javaScript: "const x=document.querySelector('#x');const value=document.querySelector('#value');const square=document.querySelector('#square');x.addEventListener('input',()=>{value.textContent=x.value;square.textContent=Number(x.value)**2;notebook.commit({x:Number(x.value)})});",
                initialState: .object(["x": .number(3)]),
                height: 190
              ),
            ]
          )
          let state = DocumentStateJournal(id: documentID, actor: actor)
          let board = BoardDocument.initial(
            itemIDs: [itemID, documentID],
            actor: actor
          )
          guard let center = board.focusedCenter(of: documentID) else {
            fatalError("Не удалось получить центр документа проверки")
          }
          let viewport = SpatialPoint(x: size.width, y: size.height)
          try store.saveDocument(document)
          try store.saveDocumentState(state)
          try store.saveBoard(board, itemIDs: Set([itemID, documentID]))
          try store.savePresence(
            SessionPresence(
              mode: .document,
              camera: SpatialCamera(
                center: center,
                scale: NotebookPresentation.fitScale(viewport: viewport)
              ),
              viewport: viewport,
              focusedItemID: documentID,
              openProgress: 1
            )
          )
        } else if startsInStack {
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
            itemID: upperNotebookID,
            pageID: upperPageID
          ) else {
            fatalError("Не удалось создать верхнюю тетрадь проверки")
          }
          if selectsLowerStackMember {
            _ = index.selectItem(itemID, actor: actor)
          }
          var board = BoardDocument.initial(
            itemIDs: [itemID, upperNotebookID],
            actor: actor
          )
          guard board.createStack(
            moving: upperNotebookID,
            onto: itemID,
            actor: actor
          ) != nil else {
            fatalError("Не удалось создать стопку проверки")
          }
          let selectedItemID = selectsLowerStackMember
            ? itemID
            : upperNotebookID
          guard let focusedCenter = board.focusedCenter(
            of: selectedItemID
          ), let stackCenter = board.stack(
            containing: selectedItemID
          )?.center else {
            fatalError("Не удалось получить центр тетради в стопке")
          }
          let viewport = SpatialPoint(x: size.width, y: size.height)
          try store.savePage(upper.page)
          try store.saveBoard(
            board,
            itemIDs: Set([itemID, upperNotebookID])
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
                focusedItemID: selectedItemID,
                openProgress: 1
              )
          )
        } else if startsAtCover {
          let board = BoardDocument.initial(
            itemIDs: [itemID],
            actor: actor
          )
          let center = board.placement(of: itemID)?.center
            ?? WorldPoint(x: 0, y: 0)
          let viewport = SpatialPoint(x: size.width, y: size.height)
          let coverScale = NotebookPresentation.coverScale(viewport: viewport)
          let cameraCenter = startsOffCenterCover
            ? center.offsetBy(
              x: 100 / coverScale,
              y: -70 / coverScale
            )
            : center
          try store.saveBoard(board, itemIDs: Set([itemID]))
          try store.savePresence(
            SessionPresence(
              mode: .cover,
              camera: SpatialCamera(
                center: cameraCenter,
                scale: coverScale
              ),
              viewport: viewport,
              focusedItemID: itemID,
              openProgress: 0
            )
          )
        }
        if startsWithCoverEraser {
          var journal = SpatialInkJournal(
            stamp: VersionStamp(counter: 0, actor: actor)
          )
          let samples = [
            SpatialInkSample(
              point: SpatialPoint(x: 150, y: 500),
              timeOffset: 0,
              width: 8,
              opacity: 1,
              force: 1,
              azimuth: 0,
              altitude: .pi / 2
            ),
            SpatialInkSample(
              point: SpatialPoint(x: 684, y: 500),
              timeOffset: 0.1,
              width: 8,
              opacity: 1,
              force: 1,
              azimuth: 0,
              altitude: .pi / 2
            ),
          ]
          guard journal.append(
            tool: .pen,
            spans: [
              SpatialInkSpan(
                surface: .cover(itemID),
                samples: samples
              )
            ],
            actor: actor
          ) != nil else {
            fatalError("Не удалось создать линию проверки ластика обложки")
          }
          try store.saveSpatialInk(journal)
        }
        try store.saveIndex(index)
        let model = NotebookAppModel(store: store, startsNearbySync: false)
        if startsWithCoverEraser {
          model.selectDrawingTool(.eraser)
        }
        return model
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
