#if DEBUG && targetEnvironment(simulator)
  import Foundation
  import NotebookCore

  @MainActor
  enum SimulatorDrawingFixture {
    static let launchArgument = "--notebook-drawing-responsiveness-fixture"
    static let fingerGestureArgument = "--notebook-simulator-finger-gestures"
    static let mixedInputArgument = "--notebook-simulator-mixed-input"
    static let coverArgument = "--notebook-nearby-cover-fixture"
    static let coverEraserArgument = "--notebook-cover-eraser-fixture"
    static let partialCoverArgument = "--notebook-partial-cover-fixture"
    static let offCenterCoverArgument = "--notebook-off-center-cover-fixture"
    static let stackArgument = "--notebook-stacked-page-fixture"
    static let lowerStackArgument = "--notebook-stacked-lower-page-fixture"
    static let stackBoardArgument = "--notebook-stacked-board-fixture"
    static let documentArgument = "--notebook-document-runtime-fixture"
    static let documentPageArgument = "--notebook-document-page-three-fixture"
    static let documentProseArgument = "--notebook-document-prose-fixture"
    static let documentLetterArgument = "--notebook-document-letter-fixture"
    static let agentElementArgument = "--notebook-agent-element-fixture"
    static let collaborationArgument = "--notebook-collaboration-fixture"
    static let historyArgument = "--notebook-history-performance-fixture"
    static let pointerArgument = "--notebook-pointer-fixture"

    static func makeModel() -> NotebookAppModel {
      let fileManager = FileManager.default
      let startsAtCover = ProcessInfo.processInfo.arguments.contains(
        coverArgument
      ) || ProcessInfo.processInfo.arguments.contains(offCenterCoverArgument)
        || ProcessInfo.processInfo.arguments.contains(coverEraserArgument)
        || ProcessInfo.processInfo.arguments.contains(partialCoverArgument)
      let startsWithCoverEraser = ProcessInfo.processInfo.arguments.contains(
        coverEraserArgument
      )
      let startsWithPartialCover = ProcessInfo.processInfo.arguments.contains(
        partialCoverArgument
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
      let startsOnLaterDocumentPage = ProcessInfo.processInfo.arguments.contains(
        documentPageArgument
      )
      let startsWithAgentElement = ProcessInfo.processInfo.arguments.contains(
        agentElementArgument
      )
      let fixtureName: String
      if ProcessInfo.processInfo.arguments.contains(historyArgument) {
        fixtureName = "HistoryPerformance"
      } else if ProcessInfo.processInfo.arguments.contains(collaborationArgument) {
        fixtureName = "SharedCollaboration"
      } else if ProcessInfo.processInfo.arguments.contains(pointerArgument) {
        fixtureName = "SharedPointer"
      } else if startsInDocument {
        fixtureName = ProcessInfo.processInfo.arguments.contains(documentProseArgument) ? "DocumentProse" : "DocumentRuntime"
      } else if startsInStack {
        fixtureName = startsOnStackBoard
          ? "StackedBoard"
          : (selectsLowerStackMember
            ? "StackedLowerPage"
            : "StackedUpperPage")
      } else if startsAtCover {
        fixtureName = startsWithPartialCover
          ? "PartialCover"
          : (startsWithCoverEraser
            ? "CoverEraser"
            : (startsOffCenterCover
              ? "OffCenterCoverTransition"
              : "NearbyCoverTransition"))
      } else if ProcessInfo.processInfo.arguments.contains(
        fingerGestureArgument
      ) {
        fixtureName = "SpatialTransition"
      } else if startsWithAgentElement {
        fixtureName = "AgentElementEditing"
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
          drawingData: try denseDrawing(size: size).dataRepresentation(),
          elements: startsWithAgentElement
            ? [
              AgentElement(
                id: "shared-element",
                kind: .web,
                frame: PageRect(x: 180, y: 280, width: 360, height: 220),
                source: "",
                html: "<div role='img' aria-label='Общий элемент'>Общий элемент</div>",
                css: "body{display:grid;place-items:center;font:700 32px -apple-system;color:#263746;background:#f6c85f;border:5px solid #263746;border-radius:28px}"
              )
            ]
            : []
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
            paperSize: ProcessInfo.processInfo.arguments.contains(documentLetterArgument) ? .letter : .a4,
            blocks: ProcessInfo.processInfo.arguments.contains(documentProseArgument)
              ? (1...3).map { chapter in
                .markdown(id: "chapter-\(chapter)", source:
                  "# Глава \(chapter)\n\n*Текст самостоятельной главы*\n\n" +
                  (1...4).map { section in
                    "## Тема \(chapter).\(section)\n\n" +
                    String(repeating: "Один лист содержит свою часть общего текста. Следующий лист продолжает мысль с того места, где закончился предыдущий. ", count: 2)
                  }.joined(separator: "\n\n"))
              }
              : [
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
              .markdown(
                id: "continuation",
                source: (1...36).map { paragraph in
                  "## Раздел \(paragraph)\n\nЭто текст следующей физической страницы. Он проверяет, что содержание течёт из листа в лист, а размер бумаги остаётся конечным."
                }.joined(separator: "\n\n")
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
          try store.saveBoard(
            BoardHierarchy(
              rootBoardID: index.rootBoardID,
              boards: [BoardNode(id: index.rootBoardID, board: board)],
              stamp: board.stamp
            ),
            items: index.items
          )
          try store.savePresence(
            SessionPresence(
              boardID: index.rootBoardID,
              mode: .document,
              camera: SpatialCamera(
                center: center,
                scale: WorkspaceItemGeometry.document(document.paperSize).fitScale(viewport: viewport)
              ),
              viewport: viewport,
              focusedItemID: documentID,
              openProgress: 1,
              documentPageIndex: startsOnLaterDocumentPage ? 2 : 0
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
            BoardHierarchy(
              rootBoardID: index.rootBoardID,
              boards: [BoardNode(id: index.rootBoardID, board: board)],
              stamp: board.stamp
            ),
            items: index.items
          )
          try store.savePresence(
            startsOnStackBoard
              ? SessionPresence(
                boardID: index.rootBoardID,
                mode: .board,
                camera: SpatialCamera(
                  center: stackCenter,
                  scale: WorkspaceItemGeometry.notebook.coverScale(viewport: viewport)
                ),
                viewport: viewport
              )
              : SessionPresence(
                boardID: index.rootBoardID,
                mode: .page,
                camera: SpatialCamera(
                  center: focusedCenter,
                  scale: WorkspaceItemGeometry.notebook.fitScale(viewport: viewport)
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
          let coverScale = WorkspaceItemGeometry.notebook.coverScale(viewport: viewport)
          let openProgress = startsWithPartialCover ? 0.18 : 0
          let cameraScale = exp(
            log(coverScale) * (1 - openProgress)
              + log(WorkspaceItemGeometry.notebook.fitScale(viewport: viewport))
                * openProgress
          )
          let cameraCenter = startsOffCenterCover
            ? center.offsetBy(
              x: 100 / coverScale,
              y: -70 / coverScale
            )
            : center
          try store.saveBoard(
            BoardHierarchy(
              rootBoardID: index.rootBoardID,
              boards: [BoardNode(id: index.rootBoardID, board: board)],
              stamp: board.stamp
            ),
            items: index.items
          )
          try store.savePresence(
            SessionPresence(
              boardID: index.rootBoardID,
              mode: .cover,
              camera: SpatialCamera(
                center: cameraCenter,
                scale: cameraScale
              ),
              viewport: viewport,
              focusedItemID: itemID,
              openProgress: openProgress
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
        try store.saveWorkspaceBundle(index: index, page: page,
          board: store.loadOrCreateBoard(workspace: index, actor: actor))
        if ProcessInfo.processInfo.arguments.contains(collaborationArgument) {
          _ = try store.loadOrCreateBoard(workspace:index,actor:actor)
          _ = try store.loadOrCreateSpatialInk(actor:actor)
          let target = CollaborationTarget(kind:.page,id:pageID)
          let reference = CollaborationReference(target:target,region:.init(x:80,y:80,width:250,height:150),
            revision:try store.referenceRevision(target:target),label:"Здесь начинается рисунок")
          _ = try store.applyCollaborationAction(.init(summary:"Пояснение к рисунку",references:[reference],
            expected:[.init(target:target,revision:page.agentStamp.revision)],operations:[
              .init(kind:.insertElement,target:target,id:"shared-element",values:[
                "kind":.string("web"),"source":.string("<div>Продолжение мысли</div>"),
                "css":.string("body{display:grid;place-items:center;font:700 32px -apple-system;color:#263746;background:#f6c85f;border:5px solid #263746;border-radius:28px}"),
                "frame":.object(["x":.number(180),"y":.number(280),"width":.number(360),"height":.number(220)])])]),actor:UUID())
        }
        if ProcessInfo.processInfo.arguments.contains(historyArgument) {
          let target = CollaborationTarget(kind: .page, id: pageID)
          let revision = try store.referenceRevision(target: target, elementID: "shared-element")
          for index in 0..<120 {
            let captured = try store.appendContext(references: [.init(target: target, elementID: "shared-element",
              revision: revision, label: "Фрагмент \(index + 1)")], author: .human, actor: actor, select: index == 119)
            if index == 119, ProcessInfo.processInfo.arguments.contains("--notebook-history-pages-fixture") {
              for reply in 1...40 {
                _ = try store.appendContext(references: [], author: .agent, actor: actor,
                  contextID: captured.id, replyTo: captured.entry.id, text: "Ответ \(reply)")
              }
            }
          }
        }
        let model = NotebookAppModel(store: store, startsNearbySync: false)
        if startsWithCoverEraser {
          model.selectDrawingTool(.eraser)
        }
        return model
      } catch {
        fatalError("Не удалось создать лист проверки инструментов: \(error)")
      }
    }

    private static func denseDrawing(size: PageSize) -> PageInkDrawing {
      let strokeCount = 80, pointsPerStroke = 64
      let horizontalInset = 80.0, verticalInset = 80.0
      let usableWidth = size.width - horizontalInset * 2
      let usableHeight = size.height - verticalInset * 2
      let strokes = (0..<strokeCount).map { strokeIndex in
        let baseX = horizontalInset + usableWidth * Double(strokeIndex) / Double(strokeCount - 1)
        let samples = (0..<pointsPerStroke).map { pointIndex in
          let progress = Double(pointIndex) / Double(pointsPerStroke - 1)
          let wave = sin(progress * .pi * 6 + Double(strokeIndex)) * 3
          return SpatialInkSample(point: .init(x: baseX + wave, y: verticalInset + usableHeight * progress),
            timeOffset: Double(pointIndex) / 120, width: 2.2, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PageInkAction(tool: .pen, samples: samples, sequence: UInt64(strokeIndex + 1))
      }
      return PageInkDrawing(actions: strokes)
    }
  }
#endif
