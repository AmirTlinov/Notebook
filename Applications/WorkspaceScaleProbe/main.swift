import Foundation
import NotebookCore

// This executable queries the app's actual prepared metadata owner. It never opens the app store.
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func milliseconds(since start: UInt64) -> Double { Double(now() - start) / 1_000_000 }
func quantiles(_ values: [Double]) -> [String: Double] {
  let sorted = values.sorted()
  return ["median_ms": sorted[sorted.count / 2], "p95_ms": sorted[sorted.count * 95 / 100], "max_ms": sorted.last!]
}
func emit(_ row: [String: Any]) {
  print(String(data: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
}
let actor = UUID(), stamp = VersionStamp(counter: 0, actor: UUID())
let viewport = SpatialPoint(x: 1194, y: 834)
var rows: [[String: Any]] = []
var checksum = 0
for (count, boardCount) in [(1000, 1000), (10_000, 10_000), (100_000, 100_000),
                            (1000, 100), (10_000, 100), (100_000, 100)] {
  let fixtureStart = now()
  var items = (0..<count).map { index in WorkspaceItem.notebook(title: "Synthetic \(index)", pageIDs: [UUID()]) }
  if boardCount < count { items[count - 1] = .board(id: items[count - 1].id, title: "Offscreen board") }
  let placements = items.enumerated().map { index, item in
    FreeItemPlacement(itemID: item.id, center: .init(x: Double(index % 316) * 2000, y: Double(index / 316) * 2000), zIndex: index, stamp: stamp)
  }
  let workspace = WorkspaceIndex(items: items, selectedItemID: items[0].id, selectedPageID: items[0].pageIDs[0], stamp: stamp)
  let currentPlacements = boardCount < count ? Array(placements.prefix(boardCount - 1)) + [placements.last!] : placements
  let board = BoardDocument(freeItems: currentPlacements, stamp: stamp)
  var nodes = [BoardNode(id: WorkspaceRoot.boardID, board: board)]
  if boardCount < count {
    nodes.append(.init(id: items.last!.id,
      board: .init(freeItems: Array(placements.dropFirst(boardCount - 1).dropLast()), stamp: stamp)))
  }
  let hierarchy = BoardHierarchy(rootBoardID: WorkspaceRoot.boardID, boards: nodes, stamp: stamp)
  precondition(hierarchy.isValid(items: items))
  let fixtureMS = milliseconds(since: fixtureStart)
  let prepareStart = now()
  let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, documents: [:])
  let prepareMS = milliseconds(since: prepareStart)
  var baselineTimes: [Double] = [], preparedTimes: [Double] = []
  var visibleCounts = Set<Int>(), visits = Set<Int>(), examinations = Set<Int>()
  for iteration in 0..<34 {
    let presence = SessionPresence(mode: .board,
      camera: .init(center: .init(x: 500 + Double(iteration % 7), y: 700), scale: 0.4), viewport: viewport)
    var start = now()
    let all = BaselineSceneProjection.items(workspace: workspace, board: board, presence: presence, documents: [:])
    let oldVisible = all.filter { BaselineSceneProjection.mountsContent(of: $0, in: presence) }
    let baselineMS = milliseconds(since: start)
    start = now()
    let visible = index.workset(presence: presence)
    let preparedMS = milliseconds(since: start)
    precondition(Set(visible.items.map(\.id)) == Set(oldVisible.map(\.id)), "Prepared and baseline sparse visibility must agree")
    precondition(visible.aggregates.isEmpty && visible.examinedEntries <= 16 && visible.visitedNodes <= 768)
    checksum &+= visible.items.count
    if iteration >= 4 {
      baselineTimes.append(baselineMS); preparedTimes.append(preparedMS)
      visibleCounts.insert(visible.items.count); visits.insert(visible.visitedNodes); examinations.insert(visible.examinedEntries)
    }
  }
  let row: [String: Any] = ["scenario": "sparse", "entities": count, "board_entities": boardCount,
    "fixture_and_validation_ms": fixtureMS, "prepare_index_ms": prepareMS, "visible_count": visibleCounts.sorted(),
    "baseline_projection_plus_visibility": quantiles(baselineTimes), "prepared_workset": quantiles(preparedTimes),
    "visited_nodes": visits.sorted(), "examined_entries": examinations.sorted(), "warmup_queries": 4, "measured_queries": 30]
  rows.append(row); emit(row)
}
for count in [1000, 10_000, 100_000] {
  let item = WorkspaceItem.notebook(title: "Dense physical owner", pageIDs: [UUID()])
  let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id, selectedPageID: item.pageIDs[0], stamp: stamp)
  let kinds: [SpatialElementKind] = [.web, .markdown, .nativeText]
  let elements = (0..<(count - 1)).map { index in
    SpatialElement(id: "element-\(index)", surface: .board, kind: kinds[index % 3],
      frame: .init(x: 0, y: 0, width: 180, height: 160), worldOrigin: .zero,
      source: "Tiny synthetic source", html: index % 3 == 0 ? "<svg/>" : "", stamp: stamp)
  }
  let board = BoardDocument(freeItems: [.init(itemID: item.id, center: .zero, zIndex: 0, stamp: stamp)], elements: elements, stamp: stamp)
  let hierarchy = BoardHierarchy(rootBoardID: WorkspaceRoot.boardID, boards: [.init(id: WorkspaceRoot.boardID, board: board)], stamp: stamp)
  precondition(hierarchy.isValid(items: workspace.items))
  let start = now()
  let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, documents: [:])
  let prepareMS = milliseconds(since: start)
  var times: [Double] = []
  var details = Set<Int>(), aggregates = Set<Int>(), examinations = Set<Int>(), visits = Set<Int>()
  for iteration in 0..<34 {
    let presence = SessionPresence(mode: .board,
      camera: .init(center: .init(x: Double(iteration % 7), y: 0), scale: 0.4), viewport: viewport)
    let start = now()
    let visible = index.workset(presence: presence, pinned: [.item(item.id), .element(elements.last!.id)])
    let queryMS = milliseconds(since: start)
    let detailCount = visible.items.count + visible.elements.count
    precondition(detailCount + visible.aggregates.count <= WorkspaceSceneIndex.detailLimit + 2)
    precondition(detailCount + visible.aggregates.reduce(0) { $0 + $1.count } == count)
    precondition(visible.examinedEntries <= WorkspaceSceneIndex.detailLimit && visible.visitedNodes <= 768)
    checksum &+= detailCount
    if iteration >= 4 {
      times.append(queryMS); details.insert(detailCount); aggregates.insert(visible.aggregates.count)
      examinations.insert(visible.examinedEntries); visits.insert(visible.visitedNodes)
    }
  }
  let row: [String: Any] = ["scenario": "dense_mixed_coincident", "entities": count, "prepare_index_ms": prepareMS,
    "prepared_workset": quantiles(times), "detail_count": details.sorted(), "aggregate_count": aggregates.sorted(),
    "visited_nodes": visits.sorted(), "examined_entries": examinations.sorted(), "represented_owners": count,
    "warmup_queries": 4, "measured_queries": 30]
  rows.append(row); emit(row)
}
let result: [String: Any] = ["kind": "production prepared metadata versus historical projection",
  "configuration": "native Mac swiftc -O and Release NotebookCore; not physical iPad rendering", "rows": rows, "checksum": checksum]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
  .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
