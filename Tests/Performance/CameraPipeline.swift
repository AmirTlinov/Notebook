import Foundation
import NotebookCore

var sink = 0
func measure(_ label: String, _ work: () throws -> Int) rethrows {
  var times: [Double] = []
  for _ in 0..<6 {
    let start = ContinuousClock.now
    sink &+= try autoreleasepool(invoking: work)
    let value = start.duration(to: .now).components
    times.append(Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15)
  }
  times.removeFirst(); times.sort()
  print(String(format: "%@ median_ms=%.4f max_ms=%.4f", label, times[2], times.last!))
}
let actor = UUID(), boardID = UUID()
let viewport = SpatialPoint(x: 834, y: 1194)
print("Mac CPU, Debug -Onone, 1 warmup + 5 samples; not an iPad FPS measurement")
for count in [10, 100, 500] {
  func sample(_ index: Int, stroke: Int, world: Bool = false) -> SpatialInkSample {
    let point = SpatialPoint(x: Double(index % 400) * 1.7 + Double(stroke % 7), y: Double(stroke % 300) * 3 + sin(Double(index) / 9) * 4 + 20)
    return .init(point: point, worldPoint: world ? .init(x: point.x, y: point.y) : nil,
      timeOffset: Double(index) / 120, width: 1.7 + Double(index % 9) / 10, opacity: 0.65 + Double(index % 6) / 20, force: 1, azimuth: 0, altitude: .pi / 2)
  }
  let drawing = PageInkDrawing(actions: (0..<count).map { row in
    .init(tool: .pen, samples: (0..<100).map { sample($0, stroke: row) }, sequence: UInt64(row + 1))
  })
  let page = PageDocument(size: .init(width: viewport.x, height: viewport.y), actor: actor,
    drawingData: try drawing.dataRepresentation())
  let stroke = PageInkAction(tool: .pen, samples: (0..<100).map { sample($0, stroke: count) })
  let stamp = VersionStamp(counter: 1, actor: actor)
  let prepared = try page.prepareInkChange(.append(stroke), stamp: stamp)
  print("points=\(count * 100) archive_bytes=\(page.drawingData.count)")
  try measure("ink_prepare_worker") { try page.prepareInkChange(.append(stroke), stamp: stamp).data.count }
  measure("ink_publish_main") {
    var page = page
    _ = page.publishInkChange(prepared)
    var undo = PencilUndoHistory()
    undo.recordAction(ownerID: page.id, actionID: stroke.id)
    return prepared.drawing.actionCount
  }
  let journal = SpatialInkJournal(actions: (0..<count).map { row in
    .init(tool: .pen, spans: [.init(surface: .board(boardID), samples: (0..<100).map { sample($0, stroke: row, world: true) })],
      stamp: .init(counter: UInt64(row + 1), actor: actor))
  }, stamp: .init(counter: UInt64(count), actor: actor))
  try measure("spatial_mesh_worker") { try SpatialInkMesh.prepare(surface: .board(boardID), journal: journal).batches.count }
  let mesh = try SpatialInkMesh.prepare(surface: .board(boardID), journal: journal)
  let camera = SpatialCamera(center: .init(x: 130, y: -200), scale: 0.7)
  measure("camera_uniforms_main") {
    mesh.batches.reduce(0) { $0 + Int($1.projection.transform(camera: camera, viewport: viewport).z) }
  }
}
let page = PageDocument(size: .init(width: 834, height: 1194), actor: actor)
try measure("faithful_page_worker") { try PageVisionRenderer.faithfulPNG(page).count }
try measure("complete_page_vision_worker") { try PageVisionRenderer.render(page).faithfulPNG.count }
print("checksum=\(sink)")

if CommandLine.arguments.contains("--workspace-copy") {
  let source = NotebookStore.defaultRoot
  let copy = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-perf-\(UUID())")
  try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: copy) }
  for name in ["workspace.json", "board.json", "spatial-ink.json", "pages", "documents", "document-states", "collaboration"] {
    let url = source.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.copyItem(at: url, to: copy.appendingPathComponent(name)) }
  }
  let store = NotebookStore(root: copy)
  let local = try store.collaborationContent()
  print("disposable_workspace_copy pages=\(local.pages.count) documents=\(local.documents.count) actions=\(local.ink.actions.count)")
  try measure("typed_workspace_read_worker") { try store.collaborationContent().pages.count }
  try measure("reload_merge_metadata_worker") {
    let content = try store.mergeCollaborationContent(nil, local: local)
    return try content.pages.count + store.collaborationActions().count + store.sharedContexts().contexts.count + store.deviceActionReceipts().count
  }
}
