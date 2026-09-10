import Foundation
import NotebookCore
import PencilKit

struct ImportedBaselineChoice: Codable, Equatable {
  let pageID: UUID
  let originalPencilKitSHA256: String
  let retainedIPadPNGSHA256: String
  let peerPNGSHA256: String
}

struct ArchiveConsolidationReport: Codable {
  let format: Int
  let workspaceID: UUID
  let inputs: [String: [SourceFileProof]]
  let beforeRecords: [ArchiveRecordProof]
  let afterRecords: [ArchiveRecordProof]
  let importedCheckpointSHA256: String
  let combinedContentSHA256: String
  let selectedIPadBaselines: [ImportedBaselineChoice]
  let retainedCurrentRecordCount: Int
  let itemCount: Int
  let pageCount: Int
  let documentCount: Int
  let spatialActionCount: Int
  let inputQuiescenceProven: Bool
  let installedApplicationsChanged: Bool
}

enum ArchiveConsolidation {
  /// Consolidation is an offline, additive import into a complete copy of the
  /// new archive. It does not bootstrap a partial checkpoint over that archive.
  static func prepare(legacyIPad: URL, legacyMac: URL, current: URL, destination: URL,
    beforePublication: (() throws -> Void)? = nil) throws -> ArchiveConsolidationReport {
    let manager = FileManager.default
    let roots = [legacyIPad, legacyMac, current].map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
    let active = NotebookStore.defaultRoot.standardizedFileURL.resolvingSymlinksInPath()
    func overlaps(_ a: URL, _ b: URL) -> Bool { a == b || a.path.hasPrefix(b.path + "/") || b.path.hasPrefix(a.path + "/") }
    guard Set(roots).count == 3, !manager.fileExists(atPath: destination.path),
      roots.allSatisfy({ !overlaps($0, active) && !overlaps($0, destination) }),
      !overlaps(destination, active),
      !overlaps(roots[0], roots[1]), !overlaps(roots[0], roots[2]), !overlaps(roots[1], roots[2]) else {
      throw ArchiveTransferError.invalidSource("use three independent backups and a new offline destination")
    }
    let inventories = try roots.map(inventory)
    let staging = destination.deletingLastPathComponent().appendingPathComponent(".notebook-consolidation-" + UUID().uuidString)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: staging) }
    let archive = staging.appendingPathComponent("archive")
    try manager.copyItem(at: roots[2], to: archive)
    guard try inventory(archive) == inventories[2] else { throw ArchiveTransferError.invalidSource("current archive copy changed") }
    let store = NotebookStore(root: archive)
    let beforeRecords = try ArchiveRecordProof.read(archive)
    guard !beforeRecords.isEmpty else { throw ArchiveTransferError.invalidSource("current archive must already contain its owners") }
    let workspaceID = try store.workspaceHeader().workspaceID
    let primary = try ArchiveSource.read(root: roots[0], workspaceID: workspaceID)
    let secondary = try ArchiveSource.read(root: roots[1], workspaceID: workspaceID)
    let equivalentPages = try verifyLegacyPair(primary: primary, secondary: secondary)
    let before = try store.collaborationContent(), presence = try store.loadPresence()
    let history = try store.sharedContexts()
    let incoming = primary.checkpoint.envelope
    let content = incoming.content!
    try requireIndependentOwners(current: before, incoming: content)
    // Historical addresses must not accidentally resolve to a newly-created
    // owner in the other archive. Reject even ambiguous textual UUID mentions;
    // never rewrite arbitrary JavaScript, state, text or receipt payloads.
    let currentEnvelope = try CollaborationEnvelope(content: before, actions: store.collaborationActions(),
      contexts: history.contexts, selection: history.selection, delivery: store.deviceActionReceipts())
    try rejectCrossReferences(incoming, owners: physicalOwners(before))
    try rejectCrossReferences(currentEnvelope, owners: physicalOwners(content))
    _ = try ArchiveRecordProof.read(archive, forbiddenOwners: physicalOwners(content))
    guard Set(incoming.contexts.map(\.id)).isDisjoint(with: currentEnvelope.contexts.map(\.id)),
      Set(incoming.actions.map(\.id)).isDisjoint(with: currentEnvelope.actions.map(\.id)),
      Set(incoming.delivery.map(\.id)).isDisjoint(with: currentEnvelope.delivery.map(\.id)) else {
      throw ArchiveTransferError.invalidSource("independent archives have colliding history identities")
    }
    let imported = try before.importingIndependent(content, actor: UUID())
    var combined = before
    try combined.merge(imported)
    try requirePreserved(before, in: combined)
    try requirePreserved(content, in: combined)
    // Selection is local attention, not imported history. Requests and their
    // stopped state remain byte-identical in the copied destination database.
    let publication = CollaborationEnvelope(content: imported, actions: incoming.actions,
      contexts: incoming.contexts, selection: nil, delivery: incoming.delivery)
    _ = try store.receiveCollaboration(publication)
    let after = try store.collaborationContent(), afterHistory = try store.sharedContexts()
    guard after == combined, try store.loadPresence() == presence, afterHistory.selection == history.selection else {
      throw ArchiveTransferError.invalidSource("consolidation changed the current selection or differs from its prepared content")
    }
    let complete = try NotebookCheckpoint(workspaceID: workspaceID,
      envelope: .init(content: after, actions: store.collaborationActions(), contexts: afterHistory.contexts,
        selection: afterHistory.selection, delivery: store.deviceActionReceipts()), presence: presence)
    try complete.validate()
    let readActions = try store.collaborationActions(), readDelivery = try store.deviceActionReceipts()
    guard preserves(incoming.contexts, afterHistory.contexts, by: \.id),
      preserves(incoming.actions, readActions, by: \.id), preserves(incoming.delivery, readDelivery, by: \.id) else {
      throw ArchiveTransferError.invalidSource("imported action history changed")
    }
    let afterRecords = try ArchiveRecordProof.read(archive)
    let changedFiles: Set<String> = ["workspace.json", "board.json", "spatial-ink.json"]
    let protected = beforeRecords.filter { !changedFiles.contains($0.file) }
    let indexed = Dictionary(uniqueKeysWithValues: afterRecords.map { ($0.address, $0) })
    guard protected.allSatisfy({ indexed[$0.address] == $0 }) else {
      throw ArchiveTransferError.invalidSource("an existing current-format owner was changed or removed")
    }
    let report = try ArchiveConsolidationReport(format: 1, workspaceID: workspaceID,
      inputs: Dictionary(uniqueKeysWithValues: zip(roots.map(\.path), inventories)),
      beforeRecords: beforeRecords, afterRecords: afterRecords,
      importedCheckpointSHA256: collaborationHash(primary.checkpoint), combinedContentSHA256: collaborationHash(after),
      selectedIPadBaselines: equivalentPages, retainedCurrentRecordCount: protected.count,
      itemCount: after.workspace.items.count, pageCount: after.pages.count, documentCount: after.documents.count,
      spatialActionCount: after.ink.actions.count, inputQuiescenceProven: false, installedApplicationsChanged: false)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: staging.appendingPathComponent("report.json"), options: .atomic)
    try beforePublication?()
    guard try roots.map(inventory) == inventories else { throw ArchiveTransferError.invalidSource("a source changed before publication") }
    try manager.moveItem(at: staging, to: destination)
    return report
  }

  private static func physicalOwners(_ content: CollaborationContent) -> Set<UUID> {
    Set(content.workspace.items.map(\.id) + content.pages.map(\.id)).subtracting([content.workspace.rootBoardID])
  }

  static func requireIndependentOwners(current: CollaborationContent, incoming: CollaborationContent) throws {
    guard current.workspace.rootBoardID == incoming.workspace.rootBoardID,
      physicalOwners(current).isDisjoint(with: physicalOwners(incoming)),
      Set(current.ink.actions.map(\.id)).isDisjoint(with: incoming.ink.actions.map(\.id)) else {
      throw ArchiveTransferError.invalidSource("independent archives have colliding physical identities")
    }
    guard let a = current.hierarchy.board(current.workspace.rootBoardID), let b = incoming.hierarchy.board(incoming.workspace.rootBoardID),
      Set(a.elements.map(\.id)).isDisjoint(with: b.elements.map(\.id)),
      Set(a.stacks.map(\.id)).isDisjoint(with: b.stacks.map(\.id)) else {
      throw ArchiveTransferError.invalidSource("independent root boards have colliding members")
    }
  }

  private static func rejectCrossReferences(_ envelope: CollaborationEnvelope, owners: Set<UUID>) throws {
    try ArchiveReferenceScan.reject(JSONEncoder().encode(envelope), owners: owners, address: "collaboration")
  }

  private static func preserves<T: Equatable, ID: Hashable>(_ before: [T], _ after: [T], by key: KeyPath<T, ID>) -> Bool {
    let indexed = Dictionary(after.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { first, _ in first })
    return indexed.count == after.count && before.allSatisfy { indexed[$0[keyPath: key]] == $0 }
  }

  static func requirePreserved(_ source: CollaborationContent, in result: CollaborationContent) throws {
    guard source.workspace.items.allSatisfy({ result.workspace.item(id: $0.id) == $0 }),
      preserves(source.pages, result.pages, by: \.id), preserves(source.documents, result.documents, by: \.id),
      preserves(source.states, result.states, by: \.id), preserves(source.ink.actions, result.ink.actions, by: \.id) else {
      throw ArchiveTransferError.invalidSource("merge would discard or alter an original owner")
    }
    let nodes = Dictionary(result.hierarchy.boards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for node in source.hierarchy.boards {
      guard let target = nodes[node.id],
        preserves(node.board.freeItems, target.board.freeItems, by: \.id), preserves(node.board.stacks, target.board.stacks, by: \.id),
        preserves(node.board.elements, target.board.elements, by: \.id),
        node.id == source.hierarchy.rootBoardID || target == node else {
        throw ArchiveTransferError.invalidSource("merge would move, overwrite or discard an original placement")
      }
    }
  }

  /// The iPad may contain later *causal ink states*, but no Mac-only content
  /// may disappear. Differently encoded baselines need identical original
  /// PencilKit bytes and stamps, not a visual similarity heuristic.
  static func verifyLegacyPair(primary: ArchiveSource, secondary: ArchiveSource) throws -> [ImportedBaselineChoice] {
    let a = primary.checkpoint.envelope, b = secondary.checkpoint.envelope
    let ac = a.content!, bc = b.content!
    guard ac.workspace == bc.workspace, ac.hierarchy == bc.hierarchy,
      ac.documents == bc.documents, ac.states == bc.states, a.actions == b.actions,
      a.contexts == b.contexts, a.selection == b.selection, a.delivery == b.delivery,
      ac.ink.stamp >= bc.ink.stamp else {
      throw ArchiveTransferError.invalidSource("legacy devices contain independent changes; no primary may be chosen silently")
    }
    let ink = Dictionary(uniqueKeysWithValues: ac.ink.actions.map { ($0.id, $0) })
    for other in bc.ink.actions {
      guard let current = ink[other.id] else { throw ArchiveTransferError.invalidSource("Mac-only ink action") }
      let lhs = try JSONValue.encode(current), rhs = try JSONValue.encode(other)
      guard case .object(var lv) = lhs, case .object(var rv) = rhs else { throw ArchiveTransferError.invalidSource("invalid ink owner") }
      for field in ["isActive", "stateStamp"] { lv[field] = nil; rv[field] = nil }
      guard lv == rv, current.stateStamp >= other.stateStamp,
        current.stateStamp != other.stateStamp || current.isActive == other.isActive else {
        throw ArchiveTransferError.invalidSource("conflicting ink action: \(other.id)")
      }
    }
    let pages = Dictionary(uniqueKeysWithValues: bc.pages.map { ($0.id, $0) })
    let proofs = [primary, secondary].map { Dictionary(uniqueKeysWithValues: $0.files.map { ($0.path, $0) }) }
    var choices: [ImportedBaselineChoice] = []
    for page in ac.pages {
      guard let other = pages[page.id] else { throw ArchiveTransferError.invalidSource("missing peer page") }
      if page == other { continue }
      guard case .object(var lhs) = try JSONValue.encode(page), case .object(var rhs) = try JSONValue.encode(other) else {
        throw ArchiveTransferError.invalidSource("invalid page owner")
      }
      lhs["drawingData"] = nil; rhs["drawingData"] = nil
      let aInk = try PageInkDrawing.decode(page.drawingData), bInk = try PageInkDrawing.decode(other.drawingData)
      let path = "migrations/before-ink-v1/pages/\(page.id.uuidString.lowercased()).json"
      func loadOriginalPage(_ source: ArchiveSource, proofs: [String: SourceFileProof]) throws -> PageDocument {
        guard let proof = proofs[path], proof.bytes <= 512 * 1024 * 1024 else {
          throw ArchiveTransferError.invalidSource("missing or oversized original ink provenance")
        }
        let data = try Data(contentsOf: source.root.appendingPathComponent(path))
        guard UInt64(data.count) == proof.bytes, digest(data) == proof.sha256 else {
          throw ArchiveTransferError.invalidSource("original ink provenance changed")
        }
        return try JSONDecoder().decode(PageDocument.self, from: data)
      }
      let originalPage = try loadOriginalPage(primary, proofs: proofs[0]), peerPage = try loadOriginalPage(secondary, proofs: proofs[1])
      guard lhs == rhs, originalPage == peerPage, originalPage.id == page.id,
        !originalPage.drawingData.isEmpty, !originalPage.drawingData.starts(with: Data("NotebookInk/".utf8)),
        originalPage.drawingStamp == page.drawingStamp, originalPage.size == page.size,
        aInk.actions.isEmpty, bInk.actions.isEmpty, aInk.baselineActionCount == bInk.baselineActionCount,
        let originalDrawing = try? PKDrawing(data: originalPage.drawingData),
        originalDrawing.strokes.count == aInk.baselineActionCount,
        let ipadPNG = aInk.baselinePNG, let macPNG = bInk.baselinePNG else {
        throw ArchiveTransferError.invalidSource("different page ink lacks identical original point provenance: \(page.id)")
      }
      choices.append(.init(pageID: page.id, originalPencilKitSHA256: digest(originalPage.drawingData),
        retainedIPadPNGSHA256: digest(ipadPNG), peerPNGSHA256: digest(macPNG)))
    }
    return choices.sorted { $0.pageID.uuidString < $1.pageID.uuidString }
  }
}
