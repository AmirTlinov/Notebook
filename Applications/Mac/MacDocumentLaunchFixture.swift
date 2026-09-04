#if DEBUG
  import Foundation
  import NotebookCore

  @MainActor
  enum MacDocumentLaunchFixture {
    static let launchArgument = "--notebook-mac-document-launch-fixture"

    static var isRequested: Bool {
      ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func makeModel() -> NotebookAppModel {
      let fileManager = FileManager.default
      let root = fileManager.temporaryDirectory
        .appendingPathComponent("NotebookMacLaunchFixture", isDirectory: true)
        .appendingPathComponent(
          String(ProcessInfo.processInfo.processIdentifier),
          isDirectory: true
        )
      do {
        if fileManager.fileExists(atPath: root.path) {
          try fileManager.removeItem(at: root)
        }

        let actor = UUID(
          uuidString: "7E7A2000-0000-4000-8000-000000000001"
        )!
        let notebookID = UUID(
          uuidString: "7E7A2000-0000-4000-8000-000000000002"
        )!
        let pageID = UUID(
          uuidString: "7E7A2000-0000-4000-8000-000000000003"
        )!
        let documentID = UUID(
          uuidString: "7E7A2000-0000-4000-8000-000000000004"
        )!
        let size = NotebookAppModel.defaultPageSize
        let initial = WorkspaceIndex.initial(
          actor: actor,
          pageSize: size,
          itemID: notebookID,
          pageID: pageID
        )
        var index = initial.index
        guard index.createDocument(
          title: "Mac WebKit launch proof",
          actor: actor,
          documentID: documentID
        ) != nil else {
          fatalError("Не удалось создать документ проверки запуска Mac")
        }

        let sections = (1...36).map { number in
          "## Раздел \(number)\n\nЖивой многостраничный документ проверяет устойчивое присоединение WebKit к окну."
        }.joined(separator: "\n\n")
        let document = DocumentDocument(
          id: documentID,
          actor: actor,
          blocks: [
            .markdown(
              id: "launch-proof",
              source: "# Проверка запуска\n\n\(sections)"
            )
          ]
        )
        let state = DocumentStateJournal(id: documentID, actor: actor)
        let board = BoardDocument.initial(
          itemIDs: [notebookID, documentID],
          actor: actor
        )
        guard let center = board.focusedCenter(of: documentID) else {
          fatalError("Не удалось разместить документ проверки запуска Mac")
        }
        let viewport = SpatialPoint(x: size.width, y: size.height)
        let store = NotebookStore(root: root)
        try store.savePage(initial.page)
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
        try store.saveIndex(index)
        try store.savePresence(
          SessionPresence(
            boardID: index.rootBoardID,
            mode: .document,
            camera: SpatialCamera(
              center: center,
              scale: NotebookPresentation.fitScale(viewport: viewport)
            ),
            viewport: viewport,
            focusedItemID: documentID,
            openProgress: 1,
            documentPageIndex: 0
          )
        )
        return NotebookAppModel(store: store, startsNearbySync: false)
      } catch {
        fatalError("Не удалось подготовить проверку запуска Mac: \(error)")
      }
    }
  }
#endif
