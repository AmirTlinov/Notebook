#if DEBUG
import Foundation
import NotebookCore

/// Only seeds ordinary stored content. No navigation, readiness, camera
/// completion, input admission or synthetic Pencil is supplied at runtime.
@MainActor enum NotebookWorkspaceJourneyFixture {
  static let argument = "--notebook-workspace-journey-fixture"
  static func makeModel() -> NotebookAppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookUITests/WorkspaceJourney")
    let store = NotebookStore(root: root)
    if ProcessInfo.processInfo.arguments.contains("--notebook-reopen-fixture"),
      FileManager.default.fileExists(atPath: root.path) {
      return NotebookAppModel(store: store, startsNearbySync: false)
    }
    do {
      if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
      let actor = UUID(), item = UUID(uuidString: "7E7A1000-0000-4000-8000-000000000002")!
      let initial = WorkspaceIndex.initial(actor: actor, pageSize: NotebookAppModel.defaultPageSize, itemID: item)
      var index = initial.index
      let first = initial.page.id
      try store.saveWorkspaceBundle(index: index, page: initial.page,
        board: store.loadOrCreateBoard(workspace: index, actor: actor))
      for number in 0..<6 {
        var page: PageDocument
        if number == 0 { page = initial.page }
        else { page = index.appendPage(in: item, actor: actor, pageSize: NotebookAppModel.defaultPageSize)!.createdPage! }
        let elements = [
          AgentElement(id: "movable", kind: .graphic, frame: .init(x: 160, y: 260, width: 320, height: 180), source: "", html: "",
            graphic: .init(shape: .rectangle, style: .init(fill: .init(red: 1, green: 0.2, blue: 0.1)), label: "Journey movable \(number + 1)")),
          AgentElement(id: "neighbor", kind: .graphic, frame: .init(x: 540, y: 540, width: 100, height: 100), source: "", html: "",
            graphic: .init(shape: .rectangle, style: .init(fill: .init(red: 0.1, green: 0.5, blue: 1)), label: "Journey neighbor \(number + 1)")),
          AgentElement(id: "leaf", kind: .graphic, frame: .init(x: 100 + Double(number) * 100, y: 780, width: 60, height: 100), source: "", html: "",
            graphic: .init(shape: .rectangle, style: .init(fill: .init(red: 0.1, green: 0.5, blue: 1))))]
        precondition(page.replaceElements(elements, actor: actor))
        let ink = PageInkAction(tool: .pen, samples: [180.0, 480.0].map { x in
          .init(point: .init(x: x, y: 660 + Double(number) * 16), timeOffset: 0, width: 8,
            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        })
        let drawing = try PageInkDrawing(actions: [ink]).dataRepresentation()
        precondition(page.replaceDrawing(drawing, actor: actor))
        if number == 0 { try store.savePage(page) }
        else { try store.saveWorkspaceSelection(index: index, createdPage: page) }
      }
      precondition(index.selectItem(item, pageID: first, actor: actor))
      try store.saveWorkspaceSelection(index: index, createdPage: nil)
      try store.savePresence(.init(boardID: index.rootBoardID, mode: .board,
        camera: .init(center: .zero, scale: 0.5), viewport: .init(x: 834, y: 1194)))
      return NotebookAppModel(store: store, startsNearbySync: false)
    } catch { fatalError("Cannot seed isolated workspace journey: \(error)") }
  }
}
#endif
