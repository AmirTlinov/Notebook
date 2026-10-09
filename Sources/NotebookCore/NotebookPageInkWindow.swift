import CoreGraphics
import Foundation

/// Complete contacts covering a region, their erasers, and explicitly retained
/// history sources. The global painter frontier remains independent of this
/// finite action set, so a new stroke cannot reuse an off-window paint slot.
public struct NotebookPageInkWindow: Sendable {
  public let pageID: UUID
  public let workspaceID: UUID
  public let source: PageInkSource
  public let coverage: CGRect
  public let pinnedActionIDs: Set<UUID>
  public let sequenceFrontier: UInt64
  public let readCursor: UInt64
  public let changeCursor: UInt64
  public let sourceRevision: String
  public let records: [String: String]
  let snapshotIdentity: UUID
  let referenceBasis: NotebookPageReferenceBasis
}

extension NotebookStore {
  public func readPageInkWindow(pageID: UUID, bounds: CGRect, pinnedActionIDs: Set<UUID> = [],
    elementIDs: Set<String> = []) throws -> NotebookPageInkWindow {
    try readPageInkWindow(pageID: pageID, bounds: bounds, pinnedActionIDs: pinnedActionIDs,
      elementIDs: elementIDs, ink: .init(store: self, pageID: pageID))
  }

  func readPageInkWindow(pageID: UUID, bounds: CGRect, pinnedActionIDs: Set<UUID>, elementIDs: Set<String>,
    ink: NotebookPageInkWindowReader) throws -> NotebookPageInkWindow {
    guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0,
      [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite),
      pinnedActionIDs.count <= 8192, elementIDs.count <= 4096 else { throw NotebookStorageError.limitExceeded("page_ink_window") }
    return try readTransaction { _ in
      let database = currentSQL!
      guard !database.writable, let snapshotIdentity = database.readSnapshotIdentity else {
        throw NotebookStorageError.invalidTransaction("page ink requires an active query cut")
      }
      guard try pageMaterialIndexIsAdmitted(database) else {
        throw CollaborationError("page_material_not_admitted", "Локальный индекс материалов страницы ещё не принят.")
      }
      let header = try readContentHeader(target: .init(kind: .page, id: pageID))
      guard let stamp = header.inkStamp, let revision = try pageSourceRevision(pageID) else {
        throw NotebookStorageError.corruptRecord(pageFile(pageID))
      }
      let addresses = try pageInkWindowAddresses(pageID: pageID, bounds: bounds, pins: pinnedActionIDs, elements: elementIDs)
      let root = pageFile(pageID) + "#/drawingData"
      let rows = try boundedStoredFragments([(root, false), (root + "/baselinePNG", false)], maximumCount: 2,
        maximumBytes: 90 * 1_024 * 1_024, budget: "page_ink_baseline")
      guard let metadata = rows.first(where: { $0.address == root }),
        metadata.file == pageFile(pageID), metadata.parent == pageFile(pageID) + "#",
        metadata.collection == "drawingData", metadata.member.isEmpty, metadata.position == 0,
        metadata.value["baselinePNG"] == nil, metadata.value["actions"] == nil,
        let count = try metadata.value["baselineActionCount"]?.decode(Int.self), (0...1_000_000).contains(count) else {
        throw NotebookStorageError.corruptRecord(root)
      }
      let baselineRow = rows.first(where: { $0.address == root + "/baselinePNG" })
      let collections: [NotebookStoredCollection] = [.init(path: ["actions"], kind: .array)]
        + (baselineRow != nil ? [.init(path: ["baselinePNG"], kind: .value)] : [])
      guard Set(metadata.collections.map(\.path)) == Set(collections.map(\.path)),
        metadata.collections.count == collections.count, collections.allSatisfy(metadata.collections.contains),
        baselineRow.map({ $0.file == pageFile(pageID) && $0.parent == root && $0.collection == "baselinePNG"
          && $0.member.isEmpty && $0.position == 0 && $0.collections.isEmpty }) ?? true else {
        throw NotebookStorageError.corruptRecord(root)
      }
      let baseline = try baselineRow?.value.decode(Data.self)
      guard baseline.map({ $0.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) && $0.count <= 64 * 1_024 * 1_024 }) ?? true else {
        throw NotebookStorageError.corruptRecord(root + "/baselinePNG")
      }
      var actions: [PageInkAction] = [], bytes = baseline?.count ?? 0, records: [String: String] = [:]
      var order: [UUID: (Int64, String)] = [:]
      for address in addresses.sorted() {
        guard let id = UUID(uuidString: String(address.dropFirst((root + "/actions/@").count))) else { throw NotebookStorageError.corruptRecord(address) }
        let action = try ink.action(id)
        bytes += action.samples.payloadBytes
        guard bytes <= 64 * 1_024 * 1_024 else { throw NotebookStorageError.limitExceeded("page_ink_window_bytes") }
        actions.append(action)
      }
      for address in addresses.sorted() + [root, root + "/baselinePNG"] {
        for row in try database.rows("SELECT address,hash,position,member FROM records WHERE address=? OR address=? ORDER BY address", [.text(address), .text(address + "/samples")]) {
          records[row[0].text!] = row[1].text!
          if row[0].text == address, let id = UUID(uuidString: row[3].text ?? "") {
            order[id] = (row[2].integer!, row[3].text!)
          }
        }
      }
      guard actions.allSatisfy({ order[$0.id] != nil }) else { throw NotebookStorageError.corruptRecord(root) }
      actions.sort { order[$0.id]! < order[$1.id]! }
      let drawing = PageInkDrawing(baselinePNG: baseline, baselineActionCount: count, actions: actions)
      guard drawing.isValid else { throw NotebookStorageError.corruptRecord(root) }
      let source = PageInkSource(source: .init(stamp: stamp, drawing: drawing))
      try source.prepareForPresentation()
      let frontier = try pageInkSequenceFrontier(pageID)
      let referenceBasis = try readPageReferenceBasis(pageID: pageID, ink: source, sequenceFrontier: frontier)
      return .init(pageID: pageID, workspaceID: try storedWorkspaceID(), source: source, coverage: bounds,
        pinnedActionIDs: pinnedActionIDs, sequenceFrontier: frontier,
        readCursor: try currentReadCursor(), changeCursor: try currentChangeCursor(), sourceRevision: revision, records: records,
        snapshotIdentity: snapshotIdentity, referenceBasis: referenceBasis)
    }
  }

  func pageInkWindowAddresses(pageID: UUID, bounds: CGRect, pins: Set<UUID>, elements: Set<String>) throws -> Set<String> {
    let surface = SurfaceID.page(pageID), root = pageFile(pageID) + "#/drawingData/actions/@"
    let coverage = WorkspaceSpatialBounds(origin: .init(x: bounds.minX, y: bounds.minY), width: bounds.width, height: bounds.height)
    return try inkWindowAddresses(coverage: [surface: coverage],
      pinnedAddresses: Set(pins.map { root + $0.uuidString.lowercased() }), elementIDs: [surface: elements.sorted()])
  }

  /// Material and ink share this one WAL cut. The first ink query opens only
  /// addresses, so claim closure precedes the single measurement-body read.
  public func readPageMaterialSource(itemID: UUID, pageID: UUID, bounds: CGRect,
    expectedVisibleRoot: String? = nil, historyPins: Set<UUID> = [], elementPins: Set<String> = [], limit: Int = 256) throws -> NotebookPageMaterialSource {
    guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0,
      [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite), historyPins.count <= 8192,
      elementPins.count <= 4096, (1...4096).contains(limit) else { throw NotebookStorageError.limitExceeded("page_material_window") }
    return try readTransaction { _ in
      guard try pageMaterialIndexIsAdmitted(currentSQL!) else {
        throw CollaborationError("page_material_not_admitted", "Локальный индекс материалов страницы ещё не принят.")
      }
      let prefix = pageFile(pageID) + "#/drawingData/actions/@"
      let addresses = try pageInkWindowAddresses(pageID: pageID, bounds: bounds, pins: historyPins, elements: [])
      let inkIDs = Set(addresses.compactMap { UUID(uuidString: String($0.dropFirst(prefix.count))) })
      let reader = NotebookPageInkWindowReader(store: self, pageID: pageID)
      let material = try readPageMaterialWindow(itemID: itemID, pageID: pageID, bounds: bounds,
        expectedVisibleRoot: expectedVisibleRoot, sourceInkIDs: inkIDs, elementPins: elementPins, limit: limit, ink: reader)
      let sourcePins = Set(material.sources.values.compactMap { $0.page?.graphic?.sourceInkContactID })
      let ink = try readPageInkWindow(pageID: pageID, bounds: bounds, pinnedActionIDs: historyPins.union(sourcePins),
        elementIDs: Set(material.sources.values.compactMap { $0.page?.id }), ink: reader)
      return try .init(material: material, ink: ink)
    }
  }
}

/// One synchronous read cut shares immutable measurements between element
/// erasure and ink preparation. No retained store or decoder escapes the cut.
final class NotebookPageInkWindowReader {
  private let store: NotebookStore
  private let pageID: UUID
  private var actions: [UUID: PageInkAction] = [:]
  private var bytes = 0
  init(store: NotebookStore, pageID: UUID) { self.store = store; self.pageID = pageID }
  func action(_ id: UUID) throws -> PageInkAction {
    if let action = actions[id] { return action }
    guard let action = try store.readPageInkAction(pageID: pageID, actionID: id)?.action else {
      throw NotebookStorageError.corruptRecord(pageFile(pageID) + "#/drawingData/actions/@" + id.uuidString.lowercased())
    }
    bytes += action.samples.payloadBytes
    guard actions.count < 8192, bytes <= 64 * 1_024 * 1_024 else { throw NotebookStorageError.limitExceeded("page_ink_window_bytes") }
    actions[id] = action
    return action
  }
}
