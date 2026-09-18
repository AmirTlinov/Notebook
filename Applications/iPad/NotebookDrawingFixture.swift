#if DEBUG
  import Foundation
  import NotebookCore

  @MainActor
  enum NotebookDrawingFixture {
    static let launchArgument = "--notebook-drawing-responsiveness-fixture"
    static let penPersistenceArgument = "--notebook-pen-persistence-fixture"
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
    static let documentLinksArgument = "--notebook-document-links-fixture"
    static let documentLetterArgument = "--notebook-document-letter-fixture"
    static let selectionTransitionArgument = "--notebook-selection-transition-fixture"
    static let agentElementArgument = "--notebook-agent-element-fixture"
    static let collaborationArgument = "--notebook-collaboration-fixture"
    static let historyArgument = "--notebook-history-performance-fixture"
    static let pointerArgument = "--notebook-pointer-fixture"
    static let passiveSVGArgument = "--notebook-passive-svg-fixture"
    static let mixedWebArgument = "--notebook-mixed-web-fixture"
    static let independentMaterialsArgument = "--notebook-independent-materials="
    static let nativeGraphicsArgument = "--notebook-native-graphics-fixture"
    static let nativeGraphicPageArgument = "--notebook-native-graphic-page"

    static func makeModel() -> NotebookAppModel {
      let fileManager = FileManager.default
      let nativeGraphics = ProcessInfo.processInfo.arguments.contains(nativeGraphicsArgument)
      let nativeGraphicPage = ProcessInfo.processInfo.arguments.contains(nativeGraphicPageArgument)
      let materialCount = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(independentMaterialsArgument) })
        .flatMap { Int($0.dropFirst(independentMaterialsArgument.count)) }
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
      // The full route reads this gesture's durable result after other UI
      // scenarios. Their fresh default fixture must not replace that evidence.
      if nativeGraphics {
        fixtureName = (nativeGraphicPage ? "NativeGraphicPage" : "NativeGraphicBoard")
          + (ProcessInfo.processInfo.arguments.contains("--notebook-native-connector") ? "Connector" : "")
          + (ProcessInfo.processInfo.arguments.contains("--notebook-native-dense") ? "Dense" : "")
          + (ProcessInfo.processInfo.arguments.contains("--notebook-native-polygons") ? "Polygons" : "")
          + (ProcessInfo.processInfo.arguments.contains("--notebook-native-geometry-edit") ? "GeometryEdit" : "")
      } else if ProcessInfo.processInfo.arguments.contains(penPersistenceArgument) {
        fixtureName = "PenPersistence"
      } else if let materialCount {
        fixtureName = "IndependentMaterials-\(materialCount)"
      } else if ProcessInfo.processInfo.arguments.contains(mixedWebArgument) {
        fixtureName = "MixedWebCamera"
      } else if ProcessInfo.processInfo.arguments.contains(passiveSVGArgument) {
        fixtureName = "PassiveSVGCamera"
      } else if ProcessInfo.processInfo.arguments.contains(historyArgument) {
        fixtureName = "HistoryPerformance"
      } else if ProcessInfo.processInfo.arguments.contains(collaborationArgument) {
        fixtureName = "SharedCollaboration"
      } else if ProcessInfo.processInfo.arguments.contains(pointerArgument) {
        fixtureName = "SharedPointer"
      } else if startsInDocument {
        fixtureName = ProcessInfo.processInfo.arguments.contains(documentLinksArgument) ? "DocumentLinks"
          : ProcessInfo.processInfo.arguments.contains(documentProseArgument) ? "DocumentProse" : "DocumentRuntime"
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
        if ProcessInfo.processInfo.arguments.contains("--notebook-reopen-fixture"),
          fileManager.fileExists(atPath: root.path) {
          return NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
        }
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
          drawingData: try (nativeGraphics ? PageInkDrawing() : denseDrawing(size: size)).dataRepresentation(),
          elements: (startsWithAgentElement
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
            : []) + (ProcessInfo.processInfo.arguments.contains(selectionTransitionArgument) ? [
              AgentElement(id: "second-element", kind: .web,
                frame: PageRect(x: 480, y: 650, width: 260, height: 220), source: "",
                html: "<div>Второй элемент</div>",
                css: "body{background:#cdeaf8;display:grid;place-items:center;font:24px -apple-system}")
            ] : [])
        )
        try store.savePage(page)
        if let materialCount {
          precondition([2, 4, 8].contains(materialCount))
          var board = BoardDocument.initial(itemIDs: [itemID], actor: actor)
          _ = board.moveItem(itemID, to: .init(x: 8_000, y: 8_000), actor: actor)
          for offset in 0..<materialCount {
            let number = offset + 1, program = offset < materialCount / 2
            let slow = materialCount == 8 && offset == 7
            let text = !program && !slow && offset == materialCount - 2
            let element = SpatialElement(id: String(format: "material-%02d", number),
              surface: .board(index.rootBoardID), kind: text ? .nativeText : .web,
              frame: .init(x: 0, y: 0, width: 170, height: 170),
              worldOrigin: .init(x: -360 + Double(offset % 4) * 185, y: -330 + Double(offset / 4) * 190),
              source: text ? "Native text" : "Material \(number)",
              html: program
                ? "<button aria-label='Program \(number)'>Add \(number)</button><output></output>"
                : "<svg xmlns='http://www.w3.org/2000/svg' role='img' aria-label='Material \(number)' viewBox='0 0 170 170'><rect width='170' height='170' fill='#def0df'/><path d='M15 150L85 15L155 150Z' fill='#23784c'/></svg>",
              css: program ? "body{padding:12px;background:#e7efff}button{width:140px;height:60px}output{display:block;margin-top:20px}" : "",
              javaScript: program
                ? "document.querySelector('button').onclick=()=>{notebook.commit({count:notebook.state.count+1});draw()};function draw(){document.querySelector('output').textContent='Program \(number) count '+notebook.state.count}addEventListener('notebookstate',draw);draw()"
                : (slow ? "notebook.ready(new Promise(resolve=>setTimeout(resolve,6000)))" : ""),
              state: .object(["count": .number(0)]), stamp: .init(counter: 0, actor: actor))
            _ = board.upsertElement(element, expected: nil, actor: actor)
          }
          try store.saveBoard(.init(rootBoardID: index.rootBoardID,
            boards: [.init(id: index.rootBoardID, board: board)], stamp: board.stamp), items: index.items)
          try store.savePresence(.init(boardID: index.rootBoardID, mode: .board,
            camera: .init(center: .zero, scale: 1), viewport: .init(x: size.width, y: size.height)))
        } else if ProcessInfo.processInfo.arguments.contains(mixedWebArgument) {
          var board = BoardDocument.initial(itemIDs: [itemID], actor: actor)
          _ = board.moveItem(itemID, to: .init(x: 8_000, y: 8_000), actor: actor)
          for element in [
            SpatialElement(id: "mixed-moodboard", surface: .board(index.rootBoardID), kind: .web,
              frame: .init(x: 0, y: 0, width: 340, height: 300), worldOrigin: .init(x: -360, y: -300),
              source: "Тихое утро", html: "<main id='board'><h1>Тихое утро</h1><a href='#photo'><svg role='img' aria-label='Утренний свет' width='300' height='180'><rect width='300' height='180' fill='#b7c6a5'/><path d='M20 150L150 20L280 150' stroke='#354e37' stroke-width='5' fill='none'/></svg></a><p id='link-result'>Место для спокойной работы</p></main>",
              css: "#board{width:340px;height:300px;padding:20px;background:#f3efe6;transform-origin:0 0}h1{font:32px Georgia;margin:0 0 12px}p{font-size:17px}a{display:block}",
              javaScript: "function fit(){document.getElementById('board').style.transform='scale('+Math.min(innerWidth/340,innerHeight/300)+')'}fit();addEventListener('resize',fit);let followed=0;addEventListener('hashchange',()=>{document.getElementById('link-result').textContent='Открыта ссылка '+(++followed)});notebook.ready(document.fonts.ready)",
              stamp: .init(counter: 0, actor: actor)),
            SpatialElement(id: "mixed-nutrition", surface: .board(index.rootBoardID), kind: .web,
              frame: .init(x: 0, y: 0, width: 320, height: 440), worldOrigin: .init(x: 30, y: -120),
              source: "Порции и КБЖУ", html: "<main id='sheet'><h1>Порции и КБЖУ</h1><p>Изменяйте граммы, а не положение листа</p><div id='menu'></div><button aria-label='Пересчитать порции'>Пересчитать</button><output id='count'></output><input type='range' aria-label='Размер порции' value='20'><footer>Итого за день</footer></main>",
              css: "#sheet{width:320px;height:440px;padding:20px;background:#f5f6eb;transform-origin:0 0}h1{font:30px Georgia;margin:0 0 12px}input,button{display:block;width:240px;height:48px;margin:10px 0}output,footer{display:block}footer{margin-top:25px}",
              javaScript: "document.getElementById('menu').innerHTML='<label>Овсянка<input aria-label=\"Овсянка, граммы\" value=\"60\"></label>';const grams=document.querySelector('#menu input');grams.addEventListener('change',()=>notebook.commit({...notebook.state,grams:grams.value}));document.querySelector('button').onclick=()=>{notebook.commit({...notebook.state,count:notebook.state.count+1});draw()};function draw(){document.getElementById('count').textContent='Count '+notebook.state.count}function fit(){document.getElementById('sheet').style.transform='scale('+Math.min(innerWidth/320,innerHeight/440)+')'}fit();addEventListener('resize',fit);addEventListener('notebookstate',draw);draw();notebook.ready(document.fonts.ready)",
              state: .object(["count": .number(0), "grams": .string("60")]), stamp: .init(counter: 0, actor: actor))
          ] { _ = board.upsertElement(element, expected: nil, actor: actor) }
          try store.saveBoard(.init(rootBoardID: index.rootBoardID,
            boards: [.init(id: index.rootBoardID, board: board)], stamp: board.stamp), items: index.items)
          try store.savePresence(.init(boardID: index.rootBoardID, mode: .board,
            camera: .init(center: .zero, scale: 1), viewport: .init(x: size.width, y: size.height)))
        } else if ProcessInfo.processInfo.arguments.contains(passiveSVGArgument) {
          var board = BoardDocument.initial(itemIDs: [itemID], actor: actor)
          _ = board.moveItem(itemID, to: .init(x: 8_000, y: 8_000), actor: actor)
          for element in [
            SpatialElement(id: "passive-svg", surface: .board(index.rootBoardID), kind: .web,
              frame: .init(x: 0, y: 0, width: 400, height: 220), worldOrigin: .init(x: -350, y: -250),
              source: "Пассивная схема", html: "<svg role='img' aria-label='Пассивная схема' xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 220'><rect width='400' height='220' fill='#ecf5ed'/><path d='M25 190L200 25L375 190' stroke='#185e3b' stroke-width='5' fill='none'/></svg>",
              stamp: .init(counter: 0, actor: actor)),
            SpatialElement(id: "svg-scene-controls", surface: .board(index.rootBoardID), kind: .web,
              frame: .init(x: 0, y: 0, width: 240, height: 200), worldOrigin: .init(x: 100, y: 80),
              source: "Controls", html: "<button aria-label='SVG scene counter'>Add</button><output id='count'>Count 0</output><input aria-label='SVG scene slider' type='range' value='20'>",
              css: "body{background:#eef4fc;padding:15px}button,input{display:block;width:180px;height:48px}",
              javaScript: "document.querySelector('button').onclick=()=>{notebook.commit({count:notebook.state.count+1});draw()};function draw(){document.getElementById('count').textContent='Count '+notebook.state.count}addEventListener('notebookstate',draw);draw()",
              state: .object(["count": .number(0)]), stamp: .init(counter: 0, actor: actor))
          ] { _ = board.upsertElement(element, expected: nil, actor: actor) }
          try store.saveBoard(.init(rootBoardID: index.rootBoardID,
            boards: [.init(id: index.rootBoardID, board: board)], stamp: board.stamp), items: index.items)
          try store.savePresence(.init(boardID: index.rootBoardID, mode: .board,
            camera: .init(center: .zero, scale: 1), viewport: .init(x: size.width, y: size.height)))
        } else if startsInDocument {
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
            blocks: ProcessInfo.processInfo.arguments.contains(documentLinksArgument)
              ? [
                .markdown(id: "contents", source: "<h1 id='contents'>Оглавление проверки</h1><p><a href='#глава:предел'>К дальней главе</a></p><p><a href='#missing'>Отсутствующий раздел</a></p>"),
                .markdown(id: "body", source: String(repeating: "Промежуточный текст занимает настоящие листы и не является целью ссылки.\n\n", count: 120)),
                .markdown(id: "destination", source: "<h1 id='глава:предел'>Дальняя глава</h1><p><a href='#contents'>К оглавлению</a></p>Содержание найдено по адресу, а не по номеру листа.")
              ]
              : ProcessInfo.processInfo.arguments.contains(documentProseArgument)
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
        if nativeGraphics {
          try installGraphics(store: store, index: index, pageID: pageID, actor: actor, onPage: nativeGraphicPage)
        }
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
        if ProcessInfo.processInfo.arguments.contains("--notebook-chat-conversation-fixture") {
          try store.saveChatPanel(.init(threadID: "7E7A1000-0000-4000-8000-000000000004"), author: model.actorID)
        }
        if ProcessInfo.processInfo.arguments.contains("--notebook-code-document-fixture") {
          let peer = UUID(uuidString: "7E7A1000-0000-4000-8000-000000000099")!
          let address = NotebookFileAddress(computer: peer, project: "fixture", root: "/fixture", path: "example.py")
          let text = (0..<500).map { "value_\($0) = \($0) * 2" }.joined(separator: "\n")
          try store.saveFileDraft(.init(address: address, text: text))
          var window = NotebookFileWindowState(); window.selected = address; window.sidebar = true
          window.project = .init(id: "fixture", name: "Code", roots: ["/fixture"])
          try store.saveFileWindow(window, author: model.actorID)
          try store.saveChatPanel(.init(sidecarID: peer), author: model.actorID)
        }
        if startsWithCoverEraser {
          model.selectDrawingTool(.eraser)
        }
        return model
      } catch {
        fatalError("Не удалось создать лист проверки инструментов: \(error)")
      }
    }

    private static func installGraphics(store: NotebookStore, index: WorkspaceIndex, pageID: UUID,
      actor: UUID, onPage: Bool) throws {
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      let target = CollaborationTarget(kind: onPage ? .page : .board, id: onPage ? pageID : index.rootBoardID)
      let before = try store.loadOrCreateBoard(workspace: index, actor: actor)
      if !onPage {
        var after = before
        _ = after.moveItem(index.selectedItemID, in: index.rootBoardID, to: .init(x: 8_000, y: 8_000), actor: actor)
        _ = try store.saveBoardEdits(before: before, after: after)
      }
      let geometryEdit = ProcessInfo.processInfo.arguments.contains("--notebook-native-geometry-edit")
      let polygons = geometryEdit || ProcessInfo.processInfo.arguments.contains("--notebook-native-polygons")
      var node: [String: JSONValue] = ["kind": .string("graphic"), "source": .string(""),
        "frame": try .encode(PageRect(x: onPage ? 80 : 0, y: onPage ? 240 : 0, width: geometryEdit ? 180 : polygons ? 40 : 200, height: geometryEdit ? 140 : polygons ? 32 : 160)),
        "graphic": try .encode(polygons ? NotebookGraphic(shape:.triangle) : NotebookGraphic(label: "Узел +"))]
      var program: [String: JSONValue] = ["kind": .string("web"), "source": .string("Live neighbour"),
        "frame": try .encode(PageRect(x: onPage ? 420 : 0, y: onPage ? 250 : 0, width: 280, height: 220)),
        "html": .string("<button aria-label='Graphic scene counter'>Add</button><output id='count'></output><input aria-label='Graphic scene draft' value='seed'><p id='runtime'></p>"),
        "css": .string("body{padding:15px;background:#edf4fc}button,input{display:block;width:240px;height:44px;margin-bottom:12px}output{display:block}p{font-size:12px}"),
        "javaScript": .string("document.querySelector('#runtime').textContent='Runtime '+Date.now()+'-'+Math.random();document.querySelector('button').onclick=()=>{notebook.commit({count:notebook.state.count+1});draw()};function draw(){document.querySelector('#count').textContent='Count '+notebook.state.count}addEventListener('notebookstate',draw);draw()"),
        "state": .object(["count": .number(0)])]
      if !onPage {
        node["worldOrigin"] = try .encode(WorldPoint(x: -340, y: -260))
        program["worldOrigin"] = try .encode(WorldPoint(x: 30, y: -240))
      }
      var operations: [CollaborationOperation] = [
          .init(kind: .insertElement, target: target, id: "native-circle", values: node),
          .init(kind: .insertElement, target: target, id: "native-neighbour", values: program)
        ]
      if ProcessInfo.processInfo.arguments.contains("--notebook-native-connector") {
        var second = node
        second["frame"] = try .encode(PageRect(x:onPage ? 100 : 20,y:onPage ? 570 : 330,width:160,height:140))
        second["graphic"] = try .encode(geometryEdit ? NotebookGraphic(shape:.rectangle) : polygons ? NotebookGraphic(shape:.diamond) : NotebookGraphic(label:"Узел −"))
        var link = node
        link["frame"] = try .encode(PageRect(x:onPage ? 180 : 100,y:onPage ? 400 : 160,width:1,height:170))
        link["graphic"] = try .encode(NotebookGraphic(shape:.connector,label:"1:2",connection:.init(
          start:.init(point:.zero,binding:.init(elementID:"native-circle")),
          end:.init(point:.init(x:0,y:170),binding:.init(elementID:"native-second")))))
        operations += [.init(kind:.insertElement,target:target,id:"native-second",values:second),
          .init(kind:.insertElement,target:target,id:"native-connection",values:link)]
      }
      if geometryEdit {
        var line = node
        line["frame"] = try .encode(PageRect(x:onPage ? 420 : 100,y:onPage ? 820 : 260,width:240,height:60))
        line["graphic"] = try .encode(NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.zero),
          end:.init(point:.init(x:240,y:60)),endArrowhead:.none)))
        if !onPage { line["worldOrigin"] = try .encode(WorldPoint.zero) }
        operations.append(.init(kind:.insertElement,target:target,id:"free-line",values:line))
      }
      if ProcessInfo.processInfo.arguments.contains("--notebook-native-dense") {
        for index in 0..<12 {
          let id = "batch-node-\(index)"
          var extra = node
          extra["frame"] = try .encode(PageRect(x: 405 + Double(index % 4) * 70,
            y: 400 + Double(index / 4) * 80, width: 52, height: 52))
          extra["graphic"] = try .encode(NotebookGraphic(label: "N\(index + 1)"))
          var link = node
          link["frame"] = try .encode(PageRect(x: 0, y: 0, width: 1, height: 1))
          link["graphic"] = try .encode(NotebookGraphic(shape: .connector, label: "D\(index + 1)", connection: .init(
            start: .init(point: .zero, binding: .init(elementID: index == 0 ? "native-circle" : "batch-node-\(index - 1)")),
            end: .init(point: .zero, binding: .init(elementID: id)))))
          operations += [.init(kind: .insertElement, target: target, id: id, values: extra),
            .init(kind: .insertElement, target: target, id: "batch-link-\(index)", values: link)]
        }
      }
      _ = try store.applyCollaborationAction(.init(summary: "Native diagram with a live neighbour",
        expected: [.init(target: target, revision: store.targetContentRevision(target: target))], operations:operations), actor:actor)
      let viewport = SpatialPoint(x: NotebookAppModel.defaultPageSize.width, y: NotebookAppModel.defaultPageSize.height)
      let center = onPage ? before.board(index.rootBoardID)?.focusedCenter(of: index.selectedItemID) ?? .zero : .zero
      try store.savePresence(.init(boardID: index.rootBoardID, mode: onPage ? .page : .board,
        camera: .init(center: center, scale: onPage ? WorkspaceItemGeometry.notebook.fitScale(viewport: viewport) : 1),
        viewport: viewport, focusedItemID: onPage ? index.selectedItemID : nil, openProgress: onPage ? 1 : 0))
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
