import Foundation
import Testing
@testable import NotebookCore

@Test("Обновление панели удаляет только прежние задания камеры и сохраняет снимки агента")
func notebookPanelRetiresObsoleteCameraJobs() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-panel-upgrade-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root), actor = UUID()
  let (workspace, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
  let target = CollaborationTarget(kind: .page, id: workspace.selectedPageID!)
  let revision = try store.targetContentRevision(target: target)
  let ordinary = try store.requestTargetRender(target: target, expectedRevision: revision)
  let obsoleteID = UUID()
  let obsolete = try JSONValue.encode(TargetRenderRequest(id: obsoleteID, target: target,
    sourceRevision: ordinary.sourceRevision, region: nil, worldOrigin: nil, pageIndex: 0,
    pageVisionRevision: nil, createdAt: Date())).setting("panelProjection", .object([
      "workspaceID": try .encode(store.storedWorkspaceID()), "camera": try .encode(SpatialCamera()),
      "viewport": try .encode(SpatialPoint(x: 834, y: 1194)), "pixelScale": .number(1)]))
  try store.publishRecords(writes: ["collaboration/render-requests/\(obsoleteID.uuidString.lowercased()).json": obsolete])
  try FileManager.default.createDirectory(at: store.targetReceiptURL(obsoleteID).deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("obsolete camera pixels".utf8).write(to: store.targetReceiptURL(obsoleteID))
  let workspaceID = try store.storedWorkspaceID()

  #expect(try store.retireObsoletePanelRenderRequests() == 1)
  #expect(try store.targetRenderRequests().map(\.id) == [ordinary.id])
  #expect(!FileManager.default.fileExists(atPath: store.targetReceiptURL(obsoleteID).path))
  #expect(try store.storedWorkspaceID() == workspaceID)
  #expect(try store.targetContentRevision(target: target) == revision)
  let cursor = try store.currentReadCursor()
  #expect(try store.retireObsoletePanelRenderRequests() == 0)
  #expect(try store.currentReadCursor() == cursor)
}
