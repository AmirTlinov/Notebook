import Foundation
import NotebookCore

/// The retired schemas exist only in this offline executable. Neither app nor
/// MCP links this target, and no method here writes to a source archive.
struct LegacyWorkspace: Decodable {
  let format: Int
  let rootBoardID: UUID
  let items: [WorkspaceItem]
  let selectedItemID: UUID
  let selectedPageID: UUID?
  let stamp: VersionStamp

  func converted() throws -> WorkspaceIndex {
    let pages = items.flatMap(\.pageIDs)
    guard format == 3, !items.isEmpty, items.count <= 100_000,
      stamp.counter <= VersionStamp.maximumCounter,
      Set(items.map(\.id)).count == items.count, pages.count <= 100_000, Set(pages).count == pages.count,
      items.allSatisfy({ item in
        item.title.utf16.count <= WorkspaceIndex.maximumTitleLength
          && (item.kind == .notebook ? !item.pageIDs.isEmpty : item.pageIDs.isEmpty)
      }), let selected = items.first(where: { $0.id == selectedItemID }),
      selected.kind == .notebook
        ? selectedPageID.map({ selected.pageIDs.contains($0) }) == true
        : selectedPageID == nil else {
      throw ArchiveTransferError.invalidSource("workspace.json: expected complete WorkspaceIndex/3")
    }
    return WorkspaceIndex(items: items, selectedItemID: selectedItemID,
      selectedPageID: selectedPageID, stamp: stamp, rootBoardID: rootBoardID)
  }
}

struct LegacyPresence: Decodable {
  let format: Int
  let boardID: UUID
  let mode: WorkspaceSemanticMode
  let camera: SpatialCamera
  let viewport: SpatialPoint
  let focusedItemID: UUID?
  let openProgress: Double
  let documentPageIndex: Int

  func converted(workspace: WorkspaceIndex) throws -> SessionPresence {
    guard format == 4, openProgress.isFinite, (0...1).contains(openProgress), documentPageIndex >= 0 else {
      throw ArchiveTransferError.invalidSource("last-context.json: expected SessionPresence/4")
    }
    let result = SessionPresence(boardID: boardID, mode: mode, camera: camera, viewport: viewport,
      focusedItemID: focusedItemID, openProgress: openProgress, documentPageIndex: documentPageIndex,
      selectedItemID: workspace.selectedItemID, notebookPageID: workspace.selectedPageID)
    guard result.isValid else { throw ArchiveTransferError.invalidSource("invalid presence") }
    return result
  }
}

private struct LegacyInk: Decodable {
  let baselinePNG: Data?
  let baselineActionCount: Int
  let actions: [LegacyInkAction]
}

private struct LegacyInkAction: Decodable {
  let id: UUID
  let tool: SpatialInkTool
  let color: SpatialInkColor
  let samples: [SpatialInkSample]
  let sequence: UInt64?
  let isActive: Bool?

  func converted(position: Int) throws -> PageInkAction {
    // These defaults are the published NotebookInk/1 meanings, not heuristics
    // inferred from a device clock. The new decoder validates before any init.
    struct Value: Encodable {
      let id: UUID; let tool: SpatialInkTool; let color: SpatialInkColor
      let samples: [SpatialInkSample]; let sequence: UInt64; let isActive: Bool
    }
    let value = Value(id: id, tool: tool, color: color, samples: samples,
      sequence: (sequence ?? 0) == 0 ? UInt64(position + 1) : sequence!, isActive: isActive ?? true)
    return try JSONDecoder().decode(PageInkAction.self, from: JSONEncoder().encode(value))
  }
}

func convertLegacyInk(_ data: Data) throws -> Data {
  if data.isEmpty { return data }
  let signature = Data("NotebookInk/1\n".utf8)
  guard data.starts(with: signature) else {
    throw ArchiveTransferError.invalidSource("live page requires NotebookInk/1; raw PencilKit must be converted separately")
  }
  let legacy = try PropertyListDecoder().decode(LegacyInk.self, from: data.dropFirst(signature.count))
  struct Value: Encodable {
    let baselinePNG: Data?; let baselineActionCount: Int; let actions: [PageInkAction]
  }
  let value = try Value(baselinePNG: legacy.baselinePNG, baselineActionCount: legacy.baselineActionCount,
    actions: legacy.actions.enumerated().map { try $0.element.converted(position: $0.offset) })
  let drawing = try JSONDecoder().decode(PageInkDrawing.self, from: JSONEncoder().encode(value))
  return try drawing.dataRepresentation()
}

func convertLegacyPage(_ data: Data) throws -> PageDocument {
  // Re-encode only the drawing field; stamps, UUIDs, element content and causal
  // metadata remain the original values. This is format conversion, not an edit.
  let original = try JSONDecoder().decode(PageDocument.self, from: data)
  guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw ArchiveTransferError.invalidSource("page must be an object")
  }
  fields["drawingData"] = try convertLegacyInk(original.drawingData).base64EncodedString()
  return try JSONDecoder().decode(PageDocument.self, from: JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
}

/// The retired app created an empty agent entry for an action without supplied
/// references. Its content owner is that exact receipt, not a new model answer.
/// Restore its existing summary only when every placeholder field matches the
/// historical producer. Empty human entries or unbound agent entries still fail.
func convertLegacyContexts(_ contexts: [SharedContext], actions: [CollaborationReceipt]) throws
  -> (contexts: [SharedContext], restoredSummaryEntryIDs: [UUID]) {
  guard Set(actions.map(\.id)).count == actions.count else {
    throw ArchiveTransferError.invalidSource("duplicate historical action UUID")
  }
  let actions = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
  var restored: [UUID] = []
  let result = try contexts.map { context in
    let entries = try context.entries.map { entry in
      guard entry.references.isEmpty, entry.text == nil else { return entry }
      guard entry.author == .agent, entry.replyTo == nil,
        entry.stamp.counter == 1, entry.stamp.actor == entry.id,
        let receipt = actions[entry.id], receipt.action.contextID == nil,
        context.id == receipt.action.resolvedContextID, receipt.createdAt == entry.createdAt,
        receipt.action.references.isEmpty,
        !receipt.action.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ArchiveTransferError.invalidSource("empty context entry has no exact historical action: \(entry.id)")
      }
      restored.append(entry.id)
      return SharedContextEntry(id: entry.id, author: entry.author, references: entry.references,
        replyTo: entry.replyTo, text: receipt.action.summary, stamp: entry.stamp,
        requiresReview: entry.requiresReview, createdAt: entry.createdAt)
    }
    let result = SharedContext(id: context.id, entries: entries)
    try result.validate()
    return result
  }
  return (result, restored.sorted { $0.uuidString < $1.uuidString })
}
