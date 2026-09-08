#if DEBUG
  import Foundation
  import AppKit
  import CryptoKit
  import NotebookCore

  @MainActor
  enum MacDocumentLaunchFixture {
    static let launchArgument = "--notebook-mac-document-launch-fixture"

    static var isRequested: Bool {
      ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// The smoke route waits for the actual background publisher's pixels,
    /// not merely for a process that has stayed alive for a few seconds.
    static func writeProof(model: NotebookAppModel) async {
      guard let path = ProcessInfo.processInfo.environment["NOTEBOOK_MAC_LAUNCH_PROOF"] else { return }
      let deadline = ContinuousClock.now + .seconds(30)
      var proof: [String: Any] = ["status": "failed", "reason": "No completed document raster"]
      while ContinuousClock.now < deadline {
        let workWindows = NSApplication.shared.windows.filter { $0.canBecomeMain || $0.styleMask.contains(.titled) }
        if !workWindows.isEmpty {
          proof["reason"] = "The helper opened a working window"
          break
        }
        if let bytes = try? Data(contentsOf: model.store.currentViewRevisionURL),
          let receipt = try? JSONDecoder().decode(CurrentViewReceipt.self, from: bytes), receipt.isValid,
          receipt.presence.mode == .document,
          let png = try? Data(contentsOf: model.store.currentViewPreviewURL),
          SHA256.hash(data: png).map({ String(format: "%02x", $0) }).joined() == receipt.pngSHA256,
          NSApplication.shared.activationPolicy() == .accessory {
          proof = ["status": "ready", "workingWindows": 0, "surface": "document",
            "pngSHA256": receipt.pngSHA256, "pngBytes": png.count]
          break
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      do {
        if proof["status"] as? String == "ready" {
          // Keep the pixels alongside the receipt so the headless proof can be
          // inspected after the isolated helper has exited.
          let png = try Data(contentsOf: model.store.currentViewPreviewURL)
          guard let expectedHash = proof["pngSHA256"] as? String,
            SHA256.hash(data: png).map({ String(format: "%02x", $0) }).joined() == expectedHash else {
            throw CocoaError(.fileReadCorruptFile)
          }
          try png.write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("png"), options: .atomic)
        }
        try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
          .write(to: URL(fileURLWithPath: path), options: .atomic)
      } catch { FileHandle.standardError.write(Data("Mac launch proof: \(error.localizedDescription)\n".utf8)) }
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
        try store.saveWorkspaceBundle(index: index, page: initial.page,
          board: store.loadBoard(items: index.items))
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
