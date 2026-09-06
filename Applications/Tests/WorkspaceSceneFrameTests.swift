import NotebookCore
import XCTest
@testable import Notebook

final class WorkspaceSceneFrameTests: XCTestCase {
  func testAllVisiblePortalsSpendOneFrameBudgetAndKeepThePinnedOwner() throws {
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: UUID())
    let rootID = WorkspaceRoot.boardID
    let portals = (0..<12).map { WorkspaceItem.board(id: UUID(), title: "Portal \($0)") }
    let placements = portals.enumerated().map { offset, item in
      FreeItemPlacement(itemID: item.id, center: .init(x: Double(offset % 4) * 1200 - 1800,
        y: Double(offset / 4) * 1400 - 1400), zIndex: offset, stamp: stamp)
    }
    let root = BoardDocument(freeItems: placements, stamp: stamp)
    var nodes = [BoardNode(id: rootID, board: root)]
    for portal in portals {
      let elements = (0..<1000).map { offset in
        SpatialElement(id: "\(portal.id)-\(offset)", surface: .board(portal.id), kind: .web,
          frame: .init(x: 0, y: 0, width: 300, height: 200),
          worldOrigin: .init(x: Double(offset % 30) * 320 - 3200, y: Double(offset / 30) * 240 - 2600),
          source: "source \(offset)", html: "<svg/>", stamp: .init(counter: 0, actor: actor))
      }
      nodes.append(.init(id: portal.id, board: .init(freeItems: [], elements: elements, stamp: stamp)))
    }
    let workspace = WorkspaceIndex(items: portals, selectedItemID: portals[0].id, selectedPageID: nil, stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: rootID, boards: nodes, stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, documents: [:])
    for budget in [32, 48, 96] {
      let presence = SessionPresence(mode: .board, camera: .init(scale: 0.15), viewport: .init(x: 1194, y: 834))
      let frame = WorkspaceSceneFrame(index: index, presence: presence,
        portalCamera: { _ in .init() }, pinned: [.item(portals[0].id)], budget: budget)
      XCTAssertLessThanOrEqual(frame.primitiveCount, budget)
      XCTAssertEqual(frame.primitiveCount, (Array(frame.worksets.values) + Array(frame.covers.values)).reduce(0) {
        $0 + $1.items.count + $1.elements.count + $1.aggregates.count
      })
      XCTAssertEqual(frame.workset(boardID: rootID).items.filter { $0.id == portals[0].id }.count, 1)
      XCTAssertGreaterThan(frame.worksets.count, 2, "Portal content receives a share, not its own unlimited budget")
      XCTAssertLessThanOrEqual(frame.visitedNodes, budget * 32)
    }
  }

  func testOneCoverCannotMountAHundredThousandNestedElementsOutsideTheFrameBudget() {
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: UUID())
    let item = WorkspaceItem.notebook(id: UUID(), title: "Dense cover", pageIDs: [UUID()])
    let elements = (0..<100_000).map { offset in
      SpatialElement(id: "cover-\(offset)", surface: .cover(item.id), kind: .web,
        frame: .init(x: 100, y: 100, width: 400, height: 400), source: "nested source \(offset)",
        html: "<svg/>", stamp: .init(counter: 0, actor: actor))
    }
    let board = BoardDocument(freeItems: [.init(itemID: item.id, center: .zero, zIndex: 0, stamp: stamp)],
      elements: elements, stamp: stamp)
    let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id, selectedPageID: item.pageIDs[0], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace,
      hierarchy: .init(rootBoardID: WorkspaceRoot.boardID, boards: [.init(id: WorkspaceRoot.boardID, board: board)], stamp: stamp),
      documents: [:])
    let presence = SessionPresence(mode: .cover, camera: .init(scale: 0.5), viewport: .init(x: 1194, y: 834),
      focusedItemID: item.id)
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil },
      pinned: [.item(item.id), .element("cover-99999")])
    let cover = frame.covers[item.id]
    XCTAssertEqual(cover?.elements.map(\.id), ["cover-99999"])
    XCTAssertEqual(cover?.aggregates.reduce(0) { $0 + $1.count }, 99_999)
    XCTAssertLessThanOrEqual(frame.primitiveCount, 96)
    XCTAssertLessThanOrEqual(frame.visitedNodes, 96 * 32)
  }
}
