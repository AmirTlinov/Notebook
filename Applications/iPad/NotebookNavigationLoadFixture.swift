import Foundation
import NotebookCore

/// Authored content only. Both native pixel/latency checks and system-routed
/// UI journeys open these same stored pages, without a readiness shortcut.
enum NotebookNavigationLoadFixture {
  static let argument = "--notebook-navigation-load-fixture"
  static let programsArgument = "--notebook-load-programs"
  static let boardArgument = "--notebook-load-board"
  static let notebookID = UUID(uuidString: "7E7A2000-0000-4000-8000-000000000002")!
  static let programCount = 24
  static let svgCount = 13

  static func frame(_ index: Int, programs: Bool) -> PageRect {
    .init(x: 45 + Double(index % 4) * 190, y: 190 + Double(index / 4) * (programs ? 130 : 190),
      width: 170, height: programs ? 110 : 160)
  }

  static func elements(leaf: Int, programs: Bool, identity: String = "load") -> [AgentElement] {
    (0..<(programs ? programCount : svgCount)).map { index in
      let id = "\(identity)-\(leaf)-\(index)", frame = frame(index, programs: programs)
      if programs {
        return .init(id: id, kind: .web, frame: frame, source: "Interactive load \(index)",
          html: "<button aria-label='Load \(leaf) control \(index)'><output>0</output></button><div id='pulse'></div>",
          css: "html,body{margin:0;width:100%;height:100%;overflow:hidden}button{position:absolute;inset:0;border:0;background:#086fff;color:white;font:28px sans-serif}#pulse{position:absolute;bottom:2px;width:8px;height:8px;background:white;pointer-events:none;animation:pulse 1s linear infinite alternate}@keyframes pulse{from{left:2px}to{left:150px}}",
          javaScript: "const button=document.querySelector('button');window.loadBoots=(window.loadBoots||0)+1;function draw(){button.querySelector('output').textContent=notebook.state.count;button.style.background=notebook.state.count?'#ef2218':'#086fff'}button.onclick=()=>{notebook.commit({count:notebook.state.count+1});draw()};addEventListener('notebookstate',draw);draw();notebook.ready(Promise.resolve())",
          state: .object(["count": .number(0)]))
      }
      // ~400 paths on a dense leaf, like the reported scientific notebook.
      let paths = (0..<(index == 0 ? 400 : 3)).map { row in
        "<path d='M0 \(row%140) " + (0..<40).map { "L\($0*4) \((row+$0)%140)" }.joined(separator: " ") + "'/>"
      }.joined()
      return .init(id: id, kind: .web, frame: frame, source: "Dense static SVG \(leaf)/\(index)",
        html: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 170 160'><rect width='170' height='160' fill='#086fff'/><g stroke='white' stroke-width='.2' fill='none'>\(paths)</g><text x='10' y='155' fill='white'>\(leaf):\(index)</text></svg>")
    }
  }

  static func seed(_ store: NotebookStore, programs: Bool, board: Bool = false) throws {
    let actor = UUID(), identity = UUID().uuidString
    let initial = WorkspaceIndex.initial(actor: actor, pageSize: .init(width: 834, height: 1194), itemID: notebookID)
    var index = initial.index
    try store.saveWorkspaceBundle(index: index, page: initial.page,
      board: store.loadOrCreateBoard(workspace: index, actor: actor))
    try store.savePresence(.init(boardID: index.rootBoardID, mode: .board,
      camera: .init(), viewport: .init(x: 834, y: 1194), selectedItemID: notebookID, notebookPageID: initial.page.id))
    for leaf in 0..<4 {
      var page = leaf == 0 ? initial.page : index.appendPage(in: notebookID, actor: actor,
        pageSize: .init(width: 834, height: 1194))!.createdPage!
      var content = elements(leaf: leaf, programs: programs, identity: identity)
      content.append(.init(id: "leaf-marker", kind: .graphic,
        frame: .init(x: 70 + Double(leaf)*90, y: 1030, width: 60, height: 30), source: "", html: "",
        graphic: .init(shape: .rectangle, style: .init(fill: .init(red: 0.1, green: 0.5, blue: 1)))))
      precondition(page.replaceElements(content, actor: actor))
      if leaf == 0 { try store.savePage(page) }
      else { try store.saveWorkspaceSelection(index: index, createdPage: page) }
    }
    _ = index.selectItem(notebookID, pageID: initial.page.id, actor: actor)
    try store.saveWorkspaceSelection(index: index, createdPage: nil)
    var hierarchy = try store.loadBoard(items: index.items)
    if board {
      _ = hierarchy.moveItem(notebookID, in: index.rootBoardID, to: .init(x: -2400, y: 0), actor: actor)
      for element in elements(leaf: 0, programs: programs, identity: identity) {
        let frame = element.frame
        let spatial = SpatialElement(id: element.id, surface: .board(index.rootBoardID), kind: .web,
          frame: .init(x: 0, y: 0, width: frame.width, height: frame.height),
          worldOrigin: .init(x: frame.x - 417, y: frame.y - 597), source: element.source,
          html: element.html, css: element.css, javaScript: element.javaScript,
          state: element.state, stamp: .init(counter: 0, actor: actor))
        precondition(hierarchy.upsertElement(spatial, in: index.rootBoardID, expected: nil, actor: actor))
      }
      try store.saveBoard(hierarchy, items: index.items)
    }
    try store.savePresence(.init(boardID: index.rootBoardID, mode: .board,
      camera: .init(center: .zero, scale: board ? 1 : 0.5), viewport: .init(x: 834, y: 1194),
      selectedItemID: notebookID, notebookPageID: initial.page.id))
  }

  #if DEBUG
  @MainActor static func makeModel() -> NotebookAppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookUITests/NavigationLoad")
    do {
      if !ProcessInfo.processInfo.arguments.contains("--notebook-reopen-fixture") {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try seed(.init(root: root), programs: ProcessInfo.processInfo.arguments.contains(programsArgument),
          board: ProcessInfo.processInfo.arguments.contains(boardArgument))
      }
      return NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    } catch { fatalError("Cannot seed isolated navigation load: \(error)") }
  }
  #endif
}
