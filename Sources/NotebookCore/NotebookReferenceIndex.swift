import CryptoKit
import Foundation

/// A content identity of one complete physical owner. Scene projections carry
/// this identity from their completed SQL cut; they do not hash unseen members.
public struct NotebookReferenceIdentity: Codable, Equatable, Sendable {
  public let target: CollaborationTarget
  public let revision: String
  public init(target: CollaborationTarget, revision: String) { self.target = target; self.revision = revision }
}

/// The complete direct ink of one physical owner, not a viewport sample. This
/// value is prepared off the input actor and includes inactive undo records.
public struct NotebookReferenceInk: Equatable, Sendable {
  public let surface: SurfaceID
  public let actions: [SpatialInkAction]

  public init(surface: SurfaceID, actions: [SpatialInkAction]) throws {
    guard surface.isValid, surface.kind != .page, Set(actions.map(\.id)).count == actions.count,
      actions.allSatisfy(\.isValid) else {
      throw CollaborationError("capture_source_changed", "Чернила указания не имеют единственного физического владельца.")
    }
    self.surface = surface
    self.actions = actions.compactMap { action in
      let spans = action.spans.filter { $0.surface == surface }
      guard !spans.isEmpty else { return nil }
      return SpatialInkAction(id: action.id, tool: action.tool, color: action.color, spans: spans,
        stamp: action.stamp, isActive: action.isActive, stateStamp: action.stateStamp)
    }.sorted { $0.stamp == $1.stamp ? $0.id.uuidString < $1.id.uuidString : $0.stamp < $1.stamp }
  }
}

/// Only a host already excluded from the retained passive pixels can replace
/// its physical contribution. This grant is transient, not agent authority.
public enum NotebookReferenceLiveOwner: Hashable, Sendable {
  case element(boardID: UUID, id: String)
  case item(boardID: UUID, id: UUID)

  fileprivate var boardID: UUID {
    switch self { case .element(let board, _), .item(let board, _): return board }
  }
}

private struct NotebookReferenceNode: Sendable {
  var digest: Data
  var hash: String
  var parent: String?
  let inkDigest: Data?
}

private struct NotebookReferenceContribution: Sendable {
  let owner: String
  let hash: String
}

private struct NotebookReferenceElementOrder: Sendable {
  let owner: String
  let member: String
  let previous: String?
  let next: String?
}

/// A transient replacement proof from the same SQL cut as a tile cohort. It
/// cannot be decoded from an agent request and is not another durable index.
public struct NotebookReferenceBasis: Sendable {
  public let workspaceID: UUID
  public let cursor: UInt64
  public var identities: [NotebookReferenceIdentity] { targets }
  private let targets: [NotebookReferenceIdentity]
  private let nodes: [String: NotebookReferenceNode]
  private let liveOwners: Set<NotebookReferenceLiveOwner>
  private let contributions: [String: NotebookReferenceContribution]
  private let elementOrder: [String: NotebookReferenceElementOrder]

  fileprivate init(workspaceID: UUID, cursor: UInt64, targets: [NotebookReferenceIdentity],
    nodes: [String: NotebookReferenceNode], liveOwners: Set<NotebookReferenceLiveOwner>,
    contributions: [String: NotebookReferenceContribution],
    elementOrder: [String: NotebookReferenceElementOrder]) {
    self.workspaceID = workspaceID; self.cursor = cursor; self.targets = targets
    self.nodes = nodes; self.liveOwners = liveOwners; self.contributions = contributions
    self.elementOrder = elementOrder
  }

  /// Replaces only retained physical contributions, then propagates their
  /// hashes through the retained parent graph. Unseen passive sources remain
  /// the exact old cut; a later SQL change cannot silently become visible here.
  public func replacing(ink: [NotebookReferenceInk], workspace: WorkspaceIndex? = nil,
    hierarchy: BoardHierarchy? = nil) throws -> [NotebookReferenceIdentity] {
    try NotebookStore.replacingReferences(ink: ink, workspace: workspace, hierarchy: hierarchy, basis: self)
  }

  fileprivate var retainedTargets: [NotebookReferenceIdentity] { targets }
  fileprivate var retainedNodes: [String: NotebookReferenceNode] { nodes }
  fileprivate var retainedLiveOwners: Set<NotebookReferenceLiveOwner> { liveOwners }
  fileprivate var retainedContributions: [String: NotebookReferenceContribution] { contributions }
  fileprivate var retainedElementOrder: [String: NotebookReferenceElementOrder] { elementOrder }
}

private struct NotebookBoundReferenceIdentities: Codable {
  let projectionHash: String
  let identities: [NotebookReferenceIdentity]
}

extension NotebookStore {
  private static let referenceIdentitiesFile = "reference-identities.json"

  /// The caller supplies identities retained with the shown scene, never tokens
  /// fetched after the contact. The binding detects a changed frozen projection.
  public static func bindReferenceIdentities(_ identities: [NotebookReferenceIdentity],
    to files: [String: JSONValue]) throws -> [String: JSONValue] {
    guard identities.count <= 512, Set(identities.map(\.target)).count == identities.count,
      identities.allSatisfy({ [.board, .cover, .page].contains($0.target.kind) && $0.revision.count == 64 }) else {
      throw CollaborationError("invalid_reference", "Проекция сохраняет уникальные идентичности физических владельцев.")
    }
    var result = files; result.removeValue(forKey: referenceIdentitiesFile)
    let binding = NotebookBoundReferenceIdentities(projectionHash: try collaborationHash(result), identities: identities)
    result[referenceIdentitiesFile] = try .encode(binding)
    return result
  }

  static func boundReferenceRevision(target: CollaborationTarget, files: [String: JSONValue]) throws -> String? {
    guard let value = files[referenceIdentitiesFile] else { return nil }
    let binding = try value.decode(NotebookBoundReferenceIdentities.self)
    var projection = files; projection.removeValue(forKey: referenceIdentitiesFile)
    guard try collaborationHash(projection) == binding.projectionHash else {
      throw CollaborationError("source_conflict", "Закреплённая проекция изменилась после получения её идентичности.")
    }
    return binding.identities.first { $0.target == target }?.revision
  }

  public func referenceIdentities(targets: [CollaborationTarget]) throws -> [NotebookReferenceIdentity] {
    guard targets.count <= 512, Set(targets).count == targets.count else { throw NotebookStorageError.limitExceeded("reference_identities") }
    return try readTransaction { _ in
      if let database = currentSQL, database.writable { try refreshReferenceIndex(database: database) }
      return try targets.map { target in
        guard [.board, .cover, .page].contains(target.kind) else { throw CollaborationError("invalid_reference", "Токен проекции принадлежит доске, обложке или листу.") }
        if target.kind == .cover, try ownerBoardID(of: target.id) != target.boardID { throw CollaborationError("target_missing", "Обложка отсутствует на указанной доске.", target: target) }
        let key = Self.referenceOwnerKey(target.kind.rawValue, target.id)
        guard let hash = try currentSQL!.rows("SELECT hash FROM reference_owners WHERE owner_key=?", [.text(key)]).first?[0].text else {
          throw CollaborationError("target_missing", "Физический владелец отсутствует.", target: target)
        }
        return .init(target: target, revision: hash)
      }
    }
  }

  /// Reads only hash contributions, in bounded pages. The preparation is linear
  /// in the addressed owners' ink; it never decodes samples or scans an archive.
  public func referenceBasis(rootBoardID: UUID, targets: [CollaborationTarget],
    surfaces: [SurfaceID], liveOwners: [NotebookReferenceLiveOwner] = []) throws -> NotebookReferenceBasis {
    guard liveOwners.count <= 15, Set(liveOwners).count == liveOwners.count,
      surfaces.count <= 15, Set(surfaces).count == surfaces.count,
      surfaces.allSatisfy({ $0.isValid && $0.kind != .page }) else {
      throw NotebookStorageError.limitExceeded("reference_live_owners")
    }
    return try readTransaction { store in
      let header = try store.workspaceHeader(), identities = try store.referenceIdentities(targets: targets)
      let root = Self.referenceOwnerKey("board", rootBoardID)
      var nodes: [String: NotebookReferenceNode] = [:]
      func readNode(_ key: String, includesInk: Bool) throws {
        if let existing = nodes[key], !includesInk || existing.inkDigest != nil { return }
        guard let row = try currentSQL!.rows("SELECT digest,hash,parent FROM reference_owners WHERE owner_key=?", [.text(key)]).first,
          let digest = row[0].blob, let hash = row[1].text else {
          throw CollaborationError("capture_source_pending", "Основа физической поверхности ещё не готова.")
        }
        var inkDigest: Data?
        if includesInk {
          var aggregate = Data(repeating: 0, count: 32)
          let prefix = "spatial-ink.json#/actions/@"
          var after = prefix
          while true {
            try Task.checkCancellation()
            let rows = try currentSQL!.rows("SELECT address,hash FROM reference_contributions WHERE owner_key=? AND address>? AND address<? ORDER BY address LIMIT 256",
              [.text(key), .text(after), .text(prefix + "\u{10ffff}")])
            for row in rows {
              guard let address = row[0].text, let hash = row[1].text else { throw NotebookStorageError.corruptRecord(key) }
              Self.xorReferenceDigest(&aggregate, Self.referenceContribution(address, hash))
              after = address
            }
            if rows.count < 256 { break }
          }
          inkDigest = aggregate
        }
        nodes[key] = .init(digest: digest, hash: hash, parent: key == root ? nil : row[2].text, inkDigest: inkDigest)
      }
      func retainPath(_ key: String) throws {
        try readNode(key, includesInk: false)
        var current = key, visited = Set<String>()
        while current != root {
          guard visited.insert(current).inserted, visited.count <= 16,
            let parent = nodes[current]?.parent else {
            throw CollaborationError("capture_source_pending", "Основа указания не содержит полную цепочку портала.")
          }
          try readNode(parent, includesInk: false)
          current = parent
        }
      }
      for identity in identities { try readNode(Self.referenceOwnerKey(identity.target.kind.rawValue, identity.target.id), includesInk: false) }
      for surface in surfaces {
        let key = Self.referenceOwnerKey(surface.kind.rawValue, surface.ownerID!)
        try readNode(key, includesInk: true); try retainPath(key)
      }
      var contributions: [String: NotebookReferenceContribution] = [:]
      var order: [String: NotebookReferenceElementOrder] = [:]
      func retainContribution(_ address: String, owner: String? = nil) throws {
        if contributions[address] != nil { return }
        let rows = try currentSQL!.rows("SELECT owner_key,hash FROM reference_contributions WHERE address=?", [.text(address)])
        guard rows.count == 1, let key = rows[0][0].text, let hash = rows[0][1].text, owner == nil || key == owner else {
          throw CollaborationError("capture_source_pending", "Живой предмет не принадлежит подготовленному источнику.")
        }
        contributions[address] = .init(owner: key, hash: hash)
        try retainPath(key)
      }
      for live in liveOwners {
        let board = Self.referenceOwnerKey("board", live.boardID), node = Self.referenceBoardAddress(live.boardID)
        try retainContribution(node, owner: board)
        switch live {
        case .element(_, let id):
          let address = node + "/board/elements/@" + fieldKey([collaborationIdentity(id)])
          try retainContribution(address)
          guard let row = try currentSQL!.rows("SELECT owner_key,position,member FROM reference_element_order WHERE address=?", [.text(address)]).first,
            let owner = row[0].text, let position = row[1].integer, let member = row[2].text,
            owner == contributions[address]?.owner else { throw NotebookStorageError.corruptRecord(address) }
          let (previous, next) = try referenceNeighbors(owner: owner, position: position, member: member, database: currentSQL!)
          order[address] = .init(owner: owner, member: member, previous: previous, next: next)
          for from in [previous, Optional(member)] {
            let edge = Self.referenceOrderAddress(owner: owner, from: from)
            try retainContribution(edge, owner: owner)
          }
        case .item(let boardID, let id):
          let cover = Self.referenceOwnerKey("cover", id)
          try retainContribution("workspace.json#/items/@" + id.uuidString.lowercased(), owner: cover)
          guard let row = try currentSQL!.rows("SELECT board_id,address FROM item_owners WHERE item_id=?", [.text(id.uuidString.lowercased())]).first,
            row[0].text == boardID.uuidString.lowercased(), let placement = row[1].text else {
            throw CollaborationError("capture_source_pending", "Положение живого предмета ещё не вошло в источник.")
          }
          try retainContribution(placement, owner: board)
        }
      }
      return .init(workspaceID: header.workspaceID, cursor: header.cursor, targets: identities, nodes: nodes,
        liveOwners: Set(liveOwners), contributions: contributions, elementOrder: order)
    }
  }

  fileprivate static func replacingReferences(ink: [NotebookReferenceInk], workspace: WorkspaceIndex?,
    hierarchy: BoardHierarchy?, basis: NotebookReferenceBasis) throws -> [NotebookReferenceIdentity] {
    guard ink.count <= 8, Set(ink.map(\.surface)).count == ink.count else { throw NotebookStorageError.limitExceeded("captured_ink_owners") }
    var nodes = basis.retainedNodes, pending = Set<String>()
    func replace(_ address: String, owner: String, previous: String?, next: String?) throws {
      guard previous != next else { return }
      guard var node = nodes[owner] else { throw CollaborationError("capture_source_pending", "Владелец не входил в сохранённую композицию.") }
      for hash in [previous, next].compactMap({ $0 }) { xorReferenceDigest(&node.digest, referenceContribution(address, hash)) }
      nodes[owner] = node; pending.insert(owner)
    }
    for source in ink {
      guard let id = source.surface.ownerID else { throw NotebookStorageError.invalidTransaction("surface owner") }
      let key = referenceOwnerKey(source.surface.kind.rawValue, id)
      guard var node = nodes[key], let previous = node.inkDigest else {
        throw CollaborationError("capture_source_pending", "Поверхность не входила в подготовленное основание указания.")
      }
      var next = Data(repeating: 0, count: 32)
      for action in source.actions {
        try Task.checkCancellation()
        let address = "spatial-ink.json#/actions/@" + action.id.uuidString.lowercased()
        xorReferenceDigest(&next, referenceContribution(address, try collaborationHash(JSONValue.encode(action))))
      }
      xorReferenceDigest(&node.digest, previous); xorReferenceDigest(&node.digest, next)
      nodes[key] = node; pending.insert(key)
    }
    if let hierarchy {
      // A frozen projection has bounded material. Its non-live rows are never
      // used to replace complete-owner hashes or unseen SQL contributions.
      let rows = try NotebookRecordCodec.encode(JSONValue.encode(hierarchy), file: "board.json")
      let byAddress = Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) })
      let liveItems = Set(basis.retainedLiveOwners.compactMap { owner -> UUID? in
        if case .item(_, let id) = owner { return id }; return nil
      })
      func replaceRoot(_ address: String, row: NotebookStoredFragment?, owner: String) throws {
        let previous = basis.retainedContributions[address]
        guard previous == nil || previous?.owner == owner else { throw NotebookStorageError.corruptRecord(address) }
        let next: String?
        if let row {
          let contributions = try referenceContributions(fragment: row) {
            // Elements have scalar source/state; retain the codec's physical
            // decoding for future addressed children, never guess their hash.
            try NotebookRecordCodec.decode(rows.filter { $0.address == address || $0.address.hasPrefix(address + "/") }, root: address)
          }
          guard contributions.count == 1, contributions[0].0 == owner else {
            throw CollaborationError("capture_source_pending", "Живой элемент сменил физическую поверхность.")
          }
          next = contributions[0].1
        } else { next = nil }
        try replace(address, owner: owner, previous: previous?.hash, next: next)
      }
      var removed = [String: NotebookReferenceElementOrder]()
      for (address, order) in basis.retainedElementOrder {
        try replaceRoot(address, row: byAddress[address], owner: order.owner)
        if byAddress[address] == nil { removed[address] = order }
      }
      let removedMembers = Dictionary(grouping: removed.values, by: \.owner).mapValues { Dictionary(uniqueKeysWithValues: $0.map { ($0.member, $0) }) }
      for order in removed.values {
        let peers = removedMembers[order.owner] ?? [:]
        let ownEdge = referenceOrderAddress(owner: order.owner, from: order.member)
        try replace(ownEdge, owner: order.owner, previous: basis.retainedContributions[ownEdge]?.hash, next: nil)
        // One surviving predecessor authors the entire removed run. Adjacent
        // live deletions do not each XOR a different guess of that edge.
        guard order.previous.map({ peers[$0] == nil }) ?? true else { continue }
        var next = order.next, visited = Set<String>()
        while let id = next, let removed = peers[id] {
          guard visited.insert(id).inserted else { throw NotebookStorageError.corruptRecord(ownEdge) }
          next = removed.next
        }
        let edge = referenceOrderAddress(owner: order.owner, from: order.previous)
        let hash = order.previous == nil && next == nil ? nil : try collaborationHash(next.map(JSONValue.string) ?? .null)
        try replace(edge, owner: order.owner, previous: basis.retainedContributions[edge]?.hash, next: hash)
      }
      for live in basis.retainedLiveOwners {
        guard case .item(let boardID, let id) = live else { continue }
        let address = referenceBoardAddress(boardID) + "/board/placements/@" + id.uuidString.lowercased()
        // Preserve the exact immutable authored heads. A singleton or capacity
        // overflow is only layout; capture never authors a new free placement.
        try replaceRoot(address, row: byAddress[address], owner: referenceOwnerKey("board", boardID))
      }
      // Headers and the replaced live roots come from the same captured model
      // value. Changed passives keep their old hashes, so sealing rejects a
      // mixed scene instead of blessing a fresh global header as current pixels.
      for boardID in Set(basis.retainedLiveOwners.map(\.boardID)) {
        let address = referenceBoardAddress(boardID)
        guard let row = byAddress[address] else { throw CollaborationError("capture_source_pending", "Доска больше не представлена.") }
        try replaceRoot(address, row: row, owner: referenceOwnerKey("board", boardID))
      }
      if let workspace {
        let items = Dictionary(uniqueKeysWithValues: workspace.items.map { ($0.id, $0) })
        for id in liveItems {
          let address = "workspace.json#/items/@" + id.uuidString.lowercased(), owner = referenceOwnerKey("cover", id)
          guard let item = items[id], let previous = basis.retainedContributions[address] else { continue }
          let value = JSONValue.object(["id": .string(id.uuidString.lowercased()), "kind": .string(item.kind.rawValue), "title": .string(item.title)])
          try replace(address, owner: owner, previous: previous.hash, next: collaborationHash(value))
        }
      }
      // A vanished admitted item no longer contributes its cover to the shown
      // board. The old cover hash itself remains available for other targets.
      for live in basis.retainedLiveOwners {
        guard case .item(let boardID, let id) = live,
          hierarchy.board(boardID)?.itemIDs.contains(id) != true else { continue }
        let key = referenceOwnerKey("cover", id), parent = referenceOwnerKey("board", boardID)
        if var child = nodes[key], child.parent == parent {
          try replace("child:" + key, owner: parent, previous: child.hash, next: nil)
          child.parent = nil; nodes[key] = child
        }
      }
    }
    // Every edge comes from the retained SQL graph, including portal covers.
    while let key = pending.first {
      pending.remove(key)
      guard var node = nodes[key] else { throw NotebookStorageError.corruptRecord(key) }
      let previous = node.hash
      let next = referenceHash(Data(("reference-owner-v2\n" + key + "\n").utf8) + node.digest)
      if next == previous { continue }
      node.hash = next; nodes[key] = node
      if let parent = node.parent {
        guard var owner = nodes[parent] else {
          throw CollaborationError("capture_source_pending", "Основа указания не содержит промежуточного владельца.")
        }
        xorReferenceDigest(&owner.digest, referenceContribution("child:" + key, previous))
        xorReferenceDigest(&owner.digest, referenceContribution("child:" + key, next))
        nodes[parent] = owner; pending.insert(parent)
      }
    }
    return try basis.retainedTargets.map { identity in
      let key = referenceOwnerKey(identity.target.kind.rawValue, identity.target.id)
      guard let node = nodes[key] else { throw NotebookStorageError.corruptRecord(key) }
      return .init(target: identity.target, revision: node.hash)
    }
  }

  private static func referenceBoardAddress(_ id: UUID) -> String { "board.json#/boards/@" + id.uuidString.lowercased() }

  private static func xorReferenceDigest(_ digest: inout Data, _ contribution: Data) {
    for (offset, byte) in contribution.enumerated() { digest[offset] ^= byte }
  }

  private static func referenceOwnerKey(_ kind: String, _ id: UUID) -> String { kind + ":" + id.uuidString.lowercased() }
  private static func referenceHash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
  private static func referenceContribution(_ address: String, _ hash: String) -> Data {
    Data(SHA256.hash(data: Data(("reference-contribution-v2\n" + address + "\n" + hash).utf8)))
  }

  /// Only roots of changed physical values are queued. Stroke samples, a source
  /// program and a board's metadata are never expanded with unrelated owners.
  func noteReferenceChange(_ address: String, file: String, database: NotebookSQLConnection) throws {
    if file.hasPrefix("pages/") {
      if let root = Self.pageReferenceRoot(address: address, file: file) {
        try database.noteOwner(.referenceRoot, root)
      }
      return
    }
    let prefixes: [String]
    if file == "workspace.json" { prefixes = ["workspace.json#/items/@"] }
    else if file == "board.json" {
      let parts = address.components(separatedBy: "/")
      guard parts.count >= 3, parts[1] == "boards", parts[2].hasPrefix("@") else { return }
      let node = parts.prefix(3).joined(separator: "/")
      if address == node { try database.noteOwner(.referenceRoot, node); return }
      prefixes = [node + "/board/placements/@", node + "/board/elements/@"]
    } else if file == "spatial-ink.json" { prefixes = [file + "#/actions/@"] }
    else if file.hasPrefix("documents/"), address == file + "#" { try database.noteOwner(.referenceRoot, address); return }
    else { return }
    for prefix in prefixes where address.hasPrefix(prefix) {
      let member = address.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
      if !member.isEmpty { try database.noteOwner(.referenceRoot, prefix + member) }
    }
  }

  /// The explicit format-two migration removes its old physical roots before
  /// this call. Retire only those indexed contributions; ordinary publication
  /// then adds canonical placements and updates the same retained parent graph.
  /// Immutable references, pinned payloads, ink and page owners are untouched.
  func retireVersionTwoPlacementReferences(database: NotebookSQLConnection) throws {
    guard database.writable, currentSQL === database else { throw NotebookStorageError.readOnlyTransaction }
    let prefix = "board.json#/boards/@"
    var after = prefix
    while true {
      try Task.checkCancellation()
      let rows = try database.rows("SELECT address,owner_key,hash FROM reference_contributions WHERE address>? AND address<? AND (address LIKE ? OR address LIKE ?) ORDER BY address,owner_key LIMIT 256",
        [.text(after), .text(prefix + "\u{10ffff}"),
          .text(prefix + "%/board/freeItems/@%"), .text(prefix + "%/board/stacks/@%")])
      guard let last = rows.last?[0].text else { return }
      for row in rows {
        guard let address = row[0].text, let owner = row[1].text, let hash = row[2].text else {
          throw NotebookStorageError.corruptRecord("placement reference contribution")
        }
        let parts = address.components(separatedBy: "/")
        guard parts.count == 6, let boardID = UUID(uuidString: String(parts[2].dropFirst())),
          owner == Self.referenceOwnerKey("board", boardID),
          try database.rows("SELECT 1 FROM records WHERE address=?", [.text(address)]).isEmpty,
          try !database.rows("SELECT 1 FROM reference_owners WHERE owner_key=?", [.text(owner)]).isEmpty else {
          throw NotebookStorageError.corruptRecord(address)
        }
        try adjustReferenceOwner(owner, contribution: Self.referenceContribution(address, hash), database: database)
        try database.run("DELETE FROM reference_contributions WHERE address=? AND owner_key=?", [.text(address), .text(owner)])
        try database.noteOwner(.referenceRoot, Self.referenceBoardAddress(boardID))
        try markReferenceOwner(owner, database: database)
      }
      after = last
    }
  }

  private func referenceContributions(address: String) throws -> [(String, String)] {
    guard let fragment = try storedFragments(address: address, descendants: false).first else { return [] }
    return try Self.referenceContributions(fragment: fragment) {
      try NotebookRecordCodec.decode(storedFragments(address: address), root: address)
    }
  }

  private static func referenceContributions(fragment: NotebookStoredFragment, read: () throws -> JSONValue) throws -> [(String, String)] {
    let address = fragment.address
    let value: JSONValue
    let owners: [String]
    if fragment.file.hasPrefix("pages/"),
      let id = UUID(uuidString: URL(fileURLWithPath: fragment.file).deletingPathExtension().lastPathComponent) {
      guard pageReferenceRoot(address: address, file: fragment.file) == address else { return [] }
      // Clocks of element fields are not printed content. Header frontiers,
      // measured ink, programs and computations retain their physical identity.
      value = fragment.parent == nil ? fragment.value.setting("collaboration", nil)
        : fragment.collection == "drawingData" ? fragment.value : try read()
      owners = [referenceOwnerKey("page", id)]
    } else if fragment.file == "workspace.json", fragment.collection == "items", let id = UUID(uuidString: fragment.member) {
      // Page membership is not printed on a cover. A page edit or turn does not
      // change the identity of its physical cover.
      value = .object(["id": .string(id.uuidString.lowercased()), "kind": fragment.value["kind"] ?? .null, "title": fragment.value["title"] ?? .null])
      owners = [Self.referenceOwnerKey("cover", id)]
    } else if fragment.file.hasPrefix("documents/"), let id = UUID(uuidString: String(fragment.file.dropFirst(10).dropLast(5))) {
      value = .object(["paperSize": fragment.value["paperSize"] ?? .null])
      owners = [Self.referenceOwnerKey("cover", id)]
    } else if fragment.file == "spatial-ink.json" {
      let action = try read().decode(SpatialInkAction.self)
      return try Set(action.spans.map(\.surface)).compactMap { surface in
        guard surface.kind != .codeFragment, let id = surface.ownerID else { return nil }
        let full = try JSONValue.encode(action)
        let content = full.setting("spans", try .encode(action.spans.filter { $0.surface == surface }))
        return (Self.referenceOwnerKey(surface.kind.rawValue, id), try collaborationHash(content))
      }
    } else if fragment.file == "board.json" {
      let parts = address.components(separatedBy: "/")
      guard parts.count >= 3, let boardID = UUID(uuidString: String(parts[2].dropFirst())) else { return [] }
      if fragment.collection == "board/elements" {
        value = try read()
        guard let surface = try value["surface"]?.decode(SurfaceID.self), let id = surface.ownerID else { return [] }
        owners = [Self.referenceOwnerKey(surface.kind.rawValue, id)]
      } else {
        value = fragment.value
        owners = [Self.referenceOwnerKey("board", boardID)]
      }
    } else { return [] }
    let hash = try collaborationHash(value)
    return owners.map { ($0, hash) }
  }

  private func referenceOwnerExists(_ key: String, database: NotebookSQLConnection) throws -> Bool {
    let parts = key.split(separator: ":")
    guard parts.count == 2 else { return false }
    let address = parts[0] == "board" ? "board.json#/boards/@" + parts[1]
      : parts[0] == "page" ? "pages/" + parts[1] + ".json#" : "workspace.json#/items/@" + parts[1]
    return try !database.rows("SELECT 1 FROM records WHERE address=?", [.text(address)]).isEmpty
  }

  private func adjustReferenceOwner(_ key: String, contribution: Data, database: NotebookSQLConnection) throws {
    var digest = try database.rows("SELECT digest FROM reference_owners WHERE owner_key=?", [.text(key)]).first?[0].blob ?? Data(repeating: 0, count: 32)
    for (offset, byte) in contribution.enumerated() { digest[offset] ^= byte }
    try database.run("INSERT INTO reference_owners(owner_key,digest) VALUES(?,?) ON CONFLICT(owner_key) DO UPDATE SET digest=excluded.digest", [.text(key), .blob(digest)])
  }

  /// The hierarchy is itself the Merkle graph: a board owns its covers, and a
  /// portal cover owns its child board. A write updates only affected ancestors.
  func refreshReferenceIndex(database: NotebookSQLConnection) throws {
    guard try database.hasOwner(.referenceRoot) else { return }
    try database.visitOwners(.referenceRoot) { address in
      if address.contains("/board/elements/@") || address.hasPrefix("pages/") {
        try updateReferenceOrder(address: address, database: database)
      }
      let old = try database.rows("SELECT owner_key,hash FROM reference_contributions WHERE address=?", [.text(address)])
      let next = try referenceContributions(address: address)
      let oldMap = Dictionary(uniqueKeysWithValues: old.map { ($0[0].text!, $0[1].text!) })
      let nextMap = Dictionary(uniqueKeysWithValues: next)
      for key in Set(oldMap.keys).union(nextMap.keys) where oldMap[key] != nextMap[key] {
        for hash in [oldMap[key], nextMap[key]].compactMap({ $0 }) {
          try adjustReferenceOwner(key, contribution: Self.referenceContribution(address, hash), database: database)
        }
        try markReferenceOwner(key, database: database)
      }
      if oldMap != nextMap {
        try database.run("DELETE FROM reference_contributions WHERE address=?", [.text(address)])
        for (key, hash) in next { try database.run("INSERT INTO reference_contributions(address,owner_key,hash) VALUES(?,?,?)", [.text(address), .text(key), .text(hash)]) }
      }
      if address.hasPrefix("board.json#/boards/@"), let id = address.dropFirst("board.json#/boards/@".count).split(separator: "/").first.flatMap({ UUID(uuidString: String($0)) }) {
        try markReferenceOwner(Self.referenceOwnerKey("board", id), database: database)
      }
    }
    try database.visitOwners(.item) { id in
      guard let id = UUID(uuidString: id) else { throw NotebookStorageError.corruptRecord("reference item") }
      try markReferenceOwner(Self.referenceOwnerKey("cover", id), database: database)
    }
    try database.visitOwners(.referenceTouched) { key in
      let parts = key.split(separator: ":")
      guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { throw NotebookStorageError.corruptRecord("reference owner") }
      let isBoard = parts[0] == "board", isPage = parts[0] == "page"
      let exists = try referenceOwnerExists(key, database: database)
      let row = try database.rows("SELECT parent,hash FROM reference_owners WHERE owner_key=?", [.text(key)]).first
      let oldParent = row?[0].text, oldHash = row?[1].text
      let newParent: String?
      if !exists || isPage { newParent = nil }
      else if isBoard {
        newParent = try !database.rows("SELECT 1 FROM records WHERE address=?", [.text("workspace.json#/items/@" + id.uuidString.lowercased())]).isEmpty ? Self.referenceOwnerKey("cover", id) : nil
      } else { newParent = try ownerBoardID(of: id).map { Self.referenceOwnerKey("board", $0) } }
      if oldParent != newParent || !exists {
        for parent in [oldParent, newParent].compactMap({ $0 }) {
          guard try referenceOwnerExists(parent, database: database) else { continue }
          if let oldHash { try adjustReferenceOwner(parent, contribution: Self.referenceContribution("child:" + key, oldHash), database: database) }
          try database.noteOwner(.referencePending, parent)
        }
      }
      if exists {
        try database.run("INSERT OR IGNORE INTO reference_owners(owner_key,digest) VALUES(?,?)", [.text(key), .blob(Data(repeating: 0, count: 32))])
        try database.run("UPDATE reference_owners SET parent=? WHERE owner_key=?", [newParent.map(NotebookSQLValue.text) ?? .null, .text(key)])
      } else {
        try database.run("DELETE FROM reference_owners WHERE owner_key=?", [.text(key)])
        try database.run("DELETE FROM reference_contributions WHERE owner_key=?", [.text(key)])
        try database.forgetOwner(.referencePending, key)
      }
    }
    while let key = try database.takeOwner(.referencePending) {
      guard let row = try database.rows("SELECT digest,hash,parent FROM reference_owners WHERE owner_key=?", [.text(key)]).first,
        let digest = row[0].blob else { continue }
      let next = Self.referenceHash(Data(("reference-owner-v2\n" + key + "\n").utf8) + digest), previous = row[1].text
      guard next != previous else { continue }
      try database.run("UPDATE reference_owners SET hash=? WHERE owner_key=?", [.text(next), .text(key)])
      if let parent = row[2].text, try referenceOwnerExists(parent, database: database) {
        for hash in [previous, next].compactMap({ $0 }) { try adjustReferenceOwner(parent, contribution: Self.referenceContribution("child:" + key, hash), database: database) }
        try database.noteOwner(.referencePending, parent)
      }
    }
  }
}

extension NotebookStore {
  /// A complete retained page computes the same physical identity as the SQL
  /// index. Partial command envelopes must supply a bound identity instead.
  static func completePageReferenceRevision(target: CollaborationTarget, value: JSONValue) throws -> String {
    let page = try value.decode(PageDocument.self)
    guard target.kind == .page, page.id == target.id, page.isValid else {
      throw CollaborationError("source_incomplete", "Нужен полный физический лист.", target: target)
    }
    let file = pageFile(target.id), owner = referenceOwnerKey("page", target.id)
    let rows = try NotebookRecordCodec.encode(value.setting("collaboration", nil), file: file)
    let fragments = Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) })
    let children = Dictionary(grouping: rows.filter { $0.parent != nil }, by: { $0.parent! })
    func read(_ address: String) throws -> JSONValue {
      var selected: [NotebookStoredFragment] = [], pending = [address]
      while let next = pending.popLast(), let row = fragments[next] {
        selected.append(row); pending += (children[next] ?? []).map(\.address)
      }
      return try NotebookRecordCodec.decode(selected, root: address)
    }
    var digest = Data(repeating: 0, count: 32), ordered: [String: [(Int, String)]] = [:]
    for row in rows where pageReferenceRoot(address: row.address, file: file) == row.address {
      for (key, hash) in try referenceContributions(fragment: row, read: { try read(row.address) }) where key == owner {
        xorReferenceDigest(&digest, referenceContribution(row.address, hash))
      }
      if let scope = try referenceOrderScope(row), let group = scope.group {
        ordered[group, default: []].append((row.position, scope.member))
      }
    }
    for (group, entries) in ordered {
      let ids = entries.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.1)
      var previous: String?
      for member in ids {
        xorReferenceDigest(&digest, referenceContribution(referenceOrderAddress(owner: owner, group: group, from: previous),
          try collaborationHash(JSONValue.string(member))))
        previous = member
      }
      if let previous {
        xorReferenceDigest(&digest, referenceContribution(referenceOrderAddress(owner: owner, group: group, from: previous),
          try collaborationHash(JSONValue.null)))
      }
    }
    return referenceHash(Data(("reference-owner-v2\n" + owner + "\n").utf8) + digest)
  }

  /// Explicit complete snapshots (checkpoint/test sources) use the same Merkle
  /// algebra as SQL. A live partial scene instead supplies its bound identities.
  static func completeReferenceRevision(target: CollaborationTarget, files: [String: JSONValue]) throws -> String {
    guard let workspace = files["workspace.json"], let hierarchy = files["board.json"] else {
      throw CollaborationError("target_missing", "Снимок владельца отсутствует.", target: target)
    }
    let items = workspace["items"]?.array ?? [], boards = hierarchy["boards"]?.array ?? []
    var fragments: [String: NotebookStoredFragment] = [:]
    var roots = Set<String>()
    for (file, value) in files where file == "workspace.json" || file == "board.json" || file == "spatial-ink.json" || file.hasPrefix("documents/") {
      for row in try NotebookRecordCodec.encode(value, file: file) {
        fragments[row.address] = row
        if (file == "workspace.json" && row.collection == "items") || (file == "board.json" && ["boards", "board/placements", "board/elements"].contains(row.collection))
          || (file == "spatial-ink.json" && row.collection == "actions") || (file.hasPrefix("documents/") && row.parent == nil) { roots.insert(row.address) }
      }
    }
    var values: [String: [NotebookStoredFragment]] = [:]
    for row in fragments.values { if let parent = row.parent { values[parent, default: []].append(row) } }
    func read(_ address: String) throws -> JSONValue {
      var rows: [NotebookStoredFragment] = [], pending = [address]
      while let next = pending.popLast(), let row = fragments[next] {
        rows.append(row); pending += (values[next] ?? []).map(\.address)
      }
      return try NotebookRecordCodec.decode(rows, root: address)
    }
    var digests: [String: Data] = [:], parents: [String: String] = [:], childCounts: [String: Int] = [:]
    for item in items { if let id = item.memberIdentity.flatMap(UUID.init(uuidString:)) { childCounts[referenceOwnerKey("cover", id)] = 0 } }
    let rootID = hierarchy["rootBoardID"]?.string.flatMap(UUID.init(uuidString:))
    for node in boards {
      guard let id = node.memberIdentity.flatMap(UUID.init(uuidString:)), let board = try node["board"]?.decode(BoardDocument.self) else { continue }
      let key = referenceOwnerKey("board", id); childCounts[key] = childCounts[key] ?? 0
      for item in board.itemIDs { parents[referenceOwnerKey("cover", item)] = key }
      if id != rootID { parents[key] = referenceOwnerKey("cover", id) }
    }
    for (child, parent) in parents {
      guard childCounts[child] != nil, childCounts[parent] != nil else { throw CollaborationError("source_incomplete", "Полный снимок не содержит владельцев связанной поверхности.", target: target) }
      childCounts[parent, default: 0] += 1
    }
    func xor(_ key: String, _ contribution: Data) {
      var digest = digests[key] ?? Data(repeating: 0, count: 32)
      for (offset, byte) in contribution.enumerated() { digest[offset] ^= byte }
      digests[key] = digest
    }
    for address in roots {
      for (key, hash) in try referenceContributions(fragment: fragments[address]!, read: { try read(address) }) where childCounts[key] != nil {
        xor(key, referenceContribution(address, hash))
      }
    }
    var ordered: [String: [(Int, String)]] = [:]
    for address in roots {
      guard let row = fragments[address], row.collection == "board/elements", let surface = try row.value["surface"]?.decode(SurfaceID.self),
        let id = surface.ownerID, let member = row.value["id"]?.string else { continue }
      ordered[referenceOwnerKey(surface.kind.rawValue, id), default: []].append((row.position, member))
    }
    for (owner, entries) in ordered {
      let ids = entries.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.1 }
      var previous: String?
      for member in ids {
        xor(owner, referenceContribution(referenceOrderAddress(owner: owner, from: previous), try collaborationHash(JSONValue.string(member))))
        previous = member
      }
      if let previous { xor(owner, referenceContribution(referenceOrderAddress(owner: owner, from: previous), try collaborationHash(JSONValue.null))) }
    }
    var pending = childCounts.filter { $0.value == 0 }.map(\.key), revisions: [String: String] = [:]
    while let key = pending.popLast() {
      let hash = referenceHash(Data(("reference-owner-v2\n" + key + "\n").utf8) + (digests[key] ?? Data(repeating: 0, count: 32)))
      revisions[key] = hash
      if let parent = parents[key] {
        xor(parent, referenceContribution("child:" + key, hash))
        childCounts[parent]! -= 1
        if childCounts[parent] == 0 { pending.append(parent) }
      }
    }
    guard revisions.count == childCounts.count else { throw CollaborationError("invalid_content", "Цикл владельцев в снимке.", target: target) }
    if target.kind == .cover, parents[referenceOwnerKey("cover", target.id)] != target.boardID.map({ referenceOwnerKey("board", $0) }) { throw CollaborationError("target_missing", "Обложка принадлежит другой доске.", target: target) }
    guard let revision = revisions[referenceOwnerKey(target.kind.rawValue, target.id)] else { throw CollaborationError("target_missing", "Физический владелец отсутствует.", target: target) }
    return revision
  }
}

extension NotebookStore {
  /// The page header and each physical value are independent contributions.
  /// A sample write invalidates its own stroke, never the whole drawing.
  private static func pageReferenceRoot(address: String, file: String) -> String? {
    let root = file + "#"
    if [root, root + "/drawingData", root + "/drawingData/baselinePNG"].contains(address) { return address }
    for prefix in [root + "/elements/@", root + "/computations/@", root + "/drawingData/actions/@"] where address.hasPrefix(prefix) {
      guard let member = address.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first else { return nil }
      return prefix + member
    }
    return nil
  }

  private static func referenceOrderScope(_ fragment: NotebookStoredFragment) throws
    -> (owner: String, group: String?, member: String)? {
    guard let member = fragment.value["id"]?.string else { return nil }
    if fragment.file.hasPrefix("pages/"),
      let id = UUID(uuidString: URL(fileURLWithPath: fragment.file).deletingPathExtension().lastPathComponent) {
      if fragment.parent == fragment.file + "#", fragment.collection == "elements" {
        return (referenceOwnerKey("page", id), "elements", member)
      }
      if fragment.parent == fragment.file + "#/drawingData", fragment.collection == "actions" {
        return (referenceOwnerKey("page", id), "ink", member)
      }
      return nil
    }
    guard fragment.file == "board.json", fragment.collection == "board/elements",
      let surface = try fragment.value["surface"]?.decode(SurfaceID.self), let id = surface.ownerID else { return nil }
    return (referenceOwnerKey(surface.kind.rawValue, id), nil, member)
  }

  private func markReferenceOwner(_ key: String, database: NotebookSQLConnection) throws {
    try database.noteOwner(.referenceTouched, key)
    try database.noteOwner(.referencePending, key)
  }

  private static func referenceOrderAddress(owner: String, group: String? = nil, from: String?) -> String {
    "reference-order:" + owner + (group.map { "|" + $0 } ?? "") + ":" + (from.map { "node/" + fieldKey([$0]) } ?? "start")
  }

  private func setReferenceEdge(owner: String, group: String? = nil, from: String?, to: String?, remove: Bool = false,
    database: NotebookSQLConnection) throws {
    let address = Self.referenceOrderAddress(owner: owner, group: group, from: from)
    let previous = try database.rows("SELECT hash FROM reference_contributions WHERE address=? AND owner_key=?", [.text(address), .text(owner)]).first?[0].text
    let next = remove || (from == nil && to == nil) ? nil : try collaborationHash(to.map(JSONValue.string) ?? .null)
    guard previous != next else { return }
    for hash in [previous, next].compactMap({ $0 }) { try adjustReferenceOwner(owner, contribution: Self.referenceContribution(address, hash), database: database) }
    if let next { try database.run("INSERT INTO reference_contributions(address,owner_key,hash) VALUES(?,?,?) ON CONFLICT(address,owner_key) DO UPDATE SET hash=excluded.hash", [.text(address), .text(owner), .text(next)]) }
    else { try database.run("DELETE FROM reference_contributions WHERE address=? AND owner_key=?", [.text(address), .text(owner)]) }
    try markReferenceOwner(owner, database: database)
  }

  private func referenceNeighbors(owner: String, position: Int64, member: String, database: NotebookSQLConnection) throws -> (String?, String?) {
    let args: [NotebookSQLValue] = [.text(owner), .integer(position), .integer(position), .text(member)]
    let previous = try database.rows("SELECT member FROM reference_element_order WHERE owner_key=? AND (position<? OR (position=? AND member<?)) ORDER BY position DESC,member DESC LIMIT 1", args).first?[0].text
    let next = try database.rows("SELECT member FROM reference_element_order WHERE owner_key=? AND (position>? OR (position=? AND member>?)) ORDER BY position,member LIMIT 1", args).first?[0].text
    return (previous, next)
  }

  /// Relative adjacency, rather than absolute SQL slots, identifies painting
  /// order. Moving one element changes at most four neighboring edges.
  private func updateReferenceOrder(address: String, database: NotebookSQLConnection) throws {
    let old = try database.rows("SELECT owner_key,position,member FROM reference_element_order WHERE address=?", [.text(address)]).first
    let fragment = try storedFragments(address: address, descendants: false).first
    let scope = try fragment.flatMap(Self.referenceOrderScope)
    let orderKey = scope.map { $0.owner + ($0.group.map { "|" + $0 } ?? "") }
    if old?[0].text == orderKey, old?[1].integer == fragment.map({ Int64($0.position) }), old?[2].text == scope?.member { return }
    if let old, let oldOwner = old[0].text, let position = old[1].integer, let oldMember = old[2].text {
      let (previous, next) = try referenceNeighbors(owner: oldOwner, position: position, member: oldMember, database: database)
      let parts = oldOwner.split(separator: "|", maxSplits: 1).map(String.init)
      let group = parts.count == 2 ? parts[1] : nil
      try setReferenceEdge(owner: parts[0], group: group, from: previous, to: next, database: database)
      try setReferenceEdge(owner: parts[0], group: group, from: oldMember, to: nil, remove: true, database: database)
      try database.run("DELETE FROM reference_element_order WHERE address=?", [.text(address)])
    }
    if let fragment, let scope, let orderKey {
      let (previous, next) = try referenceNeighbors(owner: orderKey, position: Int64(fragment.position), member: scope.member, database: database)
      try setReferenceEdge(owner: scope.owner, group: scope.group, from: previous, to: scope.member, database: database)
      try setReferenceEdge(owner: scope.owner, group: scope.group, from: scope.member, to: next, database: database)
      try database.run("INSERT INTO reference_element_order(address,owner_key,position,member) VALUES(?,?,?,?)", [.text(address), .text(orderKey), .integer(Int64(fragment.position)), .text(scope.member)])
    }
  }
}
