import Foundation

/// A prepared append carries one UUID and three authored fields, not a catalogue.
struct NotebookPageAppendAdmission {
  let itemID: UUID
  let pageID: UUID
  let rootBoardID: UUID
  let stamp: VersionStamp
  let itemVersion: ContentFieldVersion
  let orderVersion: ContentFieldVersion
  let birthVersion: ContentFieldVersion
}

private func pageAppendFieldKeys(itemID: UUID, pageID: UUID) -> [String] {
  let item = itemID.uuidString.lowercased(), page = pageID.uuidString.lowercased()
  return [fieldKey(["items", item, "exists"]), fieldKey(["items", item, "pageIDs"]),
    fieldKey(["items", item, "pageIDs", page])]
}

extension NotebookStore {
  /// The action loop has already checked its original basis in this command.
  /// This only authors the admitted current cut; it never reads or refreshes an SDK basis.
  func makePageAppendAdmission(itemID: UUID, pageID: UUID, actor: UUID, human: Bool) throws -> NotebookPageAppendAdmission {
    let (_, rootBoardID, currentStamp) = try pageAppendWorkspace()
    let itemAddress = "workspace.json#/items/@" + itemID.uuidString.lowercased()
    guard let item = try storedFragments(address: itemAddress, descendants: false).first,
      item.value["kind"]?.string == WorkspaceItemKind.notebook.rawValue else { throw CocoaError(.fileNoSuchFile) }
    try requireUnreservedPageID(pageID)
    let previous = try pageAppendVersions(keys: pageAppendFieldKeys(itemID: itemID, pageID: pageID))
    // A new action cannot mint a second birth for an existing or retired UUID.
    // Retrying publication instead reuses the original compact admission.
    guard previous[2] == nil, try ownerItemID(ofPage: pageID) == nil else {
      throw NotebookStorageError.invalidTransaction("page append birth already exists")
    }
    var counter = currentStamp.counter
    for version in previous.compactMap({ $0 }) {
      counter = max(counter, max(version.stamp.counter, version.observed.values.max() ?? 0))
    }
    guard let stamp = VersionStamp(counter: counter, actor: actor).advanced(by: actor) else {
      throw NotebookStorageError.limitExceeded("workspace clock")
    }
    let versions = previous.map { ContentFieldVersion(stamp: stamp, human: human, previous: $0) }
    guard versions.allSatisfy(\.isValid) else { throw NotebookStorageError.limitExceeded("page append causal actors") }
    return .init(itemID: itemID, pageID: pageID, rootBoardID: rootBoardID, stamp: stamp,
      itemVersion: versions[0], orderVersion: versions[1], birthVersion: versions[2])
  }

  /// The single addressed append owner for native landings and admitted actions.
  /// Local presence and the UI's projected pageIDs never enter content publication.
  func publishPageAppend(page: PageDocument, admission: NotebookPageAppendAdmission, human: Bool) throws {
    let (root, rootBoardID, currentStamp) = try pageAppendWorkspace()
    guard rootBoardID == admission.rootBoardID, admission.stamp.counter <= VersionStamp.maximumCounter else {
      throw NotebookStorageError.invalidTransaction("page landing workspace")
    }
    let itemID = admission.itemID, item = itemID.uuidString.lowercased()
    let itemAddress = "workspace.json#/items/@" + item
    guard let storedItem = try storedFragments(address: itemAddress, descendants: false).first,
      storedItem.value["kind"]?.string == WorkspaceItemKind.notebook.rawValue,
      page.id == admission.pageID, page.isValid else {
      throw NotebookStorageError.invalidTransaction("page append identity")
    }
    let database = currentSQL!, pageID = page.id.uuidString.lowercased()
    let pageAddress = itemAddress + "/pageIDs/@" + pageID
    let keys = pageAppendFieldKeys(itemID: itemID, pageID: page.id)
    let authored = [admission.itemVersion, admission.orderVersion, admission.birthVersion]
    guard authored.allSatisfy({ $0.isValid && $0.human == human }) else {
      throw NotebookStorageError.invalidTransaction("page append causal field")
    }
    let previous = try pageAppendVersions(keys: keys)
    let owner = try ownerItemID(ofPage: page.id)
    guard owner == nil || owner == itemID else { throw NotebookStorageError.invalidTransaction("page already belongs to another notebook") }
    let existing = try storedFragments(address: pageAddress, descendants: false).first
    let currentOrder = try readPageOrder(itemID)
    // Membership tombstones are not reusable UUID reservations. A retry of
    // an already committed append has its live membership; a deleted one does not.
    guard existing != nil || previous[2] == nil else { throw CocoaError(.fileNoSuchFile) }
    if existing == nil {
      // Native pending landings bypass makePageAppendAdmission. Only a new
      // membership is reserved; retrying its live birth keeps the first stroke.
      try requireUnreservedPageID(page.id)
      let maximum = try database.rows("SELECT COALESCE(MAX(position),-1) FROM records INDEXED BY record_order WHERE parent=? AND collection='pageIDs'", [.text(itemAddress)]).first![0].integer!
      guard maximum >= 0, maximum < Int64.max else { throw NotebookStorageError.limitExceeded("page_sequence") }
      try writeFragment(.init(address: pageAddress, file: "workspace.json", parent: itemAddress,
        collection: "pageIDs", member: pageID, position: Int(maximum + 1), value: .string(page.id.uuidString), collections: []), database: database)
    }
    _ = try savePage(page)
    var frontier = max(currentStamp, admission.stamp)
    for version in previous.compactMap({ $0 }) { frontier = max(frontier, version.stamp) }
    // Append is executed at the current tail. If another accepted catalogue
    // edit overtook this intent, only the order advances, never its UUID/birth.
    if existing == nil, frontier >= admission.stamp, currentStamp >= admission.stamp {
      guard let advanced = frontier.advanced(by: authored[2].stamp.actor) else { throw NotebookStorageError.limitExceeded("workspace clock") }
      frontier = advanced
    }
    let nextOrder: NotebookPageOrderRegister
    if existing == nil {
      let nextRoot = try NotebookPageOrderVector.append(to: currentOrder.visibleRoot, pageID: page.id,
        read: { try readPageOrderNode($0) }, write: { try writePageOrderNode($0) })
      nextOrder = try .authored(root: nextRoot, stamp: frontier, human: human, previous: currentOrder)
      try writePageOrder(nextOrder, itemID: itemID)
    } else { nextOrder = currentOrder }
    for (offset, key) in keys.enumerated() {
      let joined = try previous[offset].map { try $0.joining(authored[offset]) } ?? authored[offset]
      let version = offset == 1 ? nextOrder.fieldVersion : existing == nil && offset == 0
        ? ContentFieldVersion(stamp: frontier, human: human, previous: joined) : joined
      guard version.isValid else { throw NotebookStorageError.limitExceeded("page append causal actors") }
      if version != previous[offset] {
        try writeFragment(.init(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), file: "workspace.json",
          parent: "workspace.json#", collection: "collaboration/fields", member: key, position: 0,
          value: try .encode(version), collections: []), database: database)
      }
    }
    if frontier != currentStamp { try writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(frontier))), database: database) }
  }

  /// Native adaptation owns selection/presence and extracts the prepared intent.
  /// The shared content owner above never receives a WorkspaceIndex.
  func publishPageLanding(index: WorkspaceIndex, createdPage: PageDocument?) throws {
    guard index.format == WorkspaceIndex.formatVersion, index.stamp.counter <= VersionStamp.maximumCounter else {
      throw NotebookStorageError.invalidTransaction("page landing workspace")
    }
    guard try hasStoredValue(at: presenceURL) else {
      throw CollaborationError("dependency_missing", "Выбор листа требует подготовленного присутствия устройства.")
    }
    let presence = try loadPresence(), itemID = index.selectedItemID
    if let page = createdPage {
      guard index.selectedPageID == page.id, index.item(id: itemID)?.pageIDs.last == page.id else {
        throw NotebookStorageError.invalidTransaction("page append identity")
      }
      let keys = pageAppendFieldKeys(itemID: itemID, pageID: page.id)
      let versions = try keys.map { key in
        guard let version = index.collaboration.fields[key] else { throw NotebookStorageError.invalidTransaction("page append causal field") }
        return version
      }
      try publishPageAppend(page: page, admission: .init(itemID: itemID, pageID: page.id,
        rootBoardID: index.rootBoardID, stamp: index.stamp, itemVersion: versions[0],
        orderVersion: versions[1], birthVersion: versions[2]), human: true)
    } else {
      let (_, rootBoardID, _) = try pageAppendWorkspace()
      guard rootBoardID == index.rootBoardID else { throw NotebookStorageError.invalidTransaction("page landing workspace") }
      let address = "workspace.json#/items/@" + itemID.uuidString.lowercased()
      guard let item = try storedFragments(address: address, descendants: false).first,
        let kind = item.value["kind"]?.string.flatMap(WorkspaceItemKind.init(rawValue:)) else { throw CocoaError(.fileNoSuchFile) }
      if kind == .notebook {
        guard let pageID = index.selectedPageID, try ownerItemID(ofPage: pageID) == itemID,
          try hasStoredValue(pageFile(pageID)) else { throw CocoaError(.fileNoSuchFile) }
      } else if index.selectedPageID != nil { throw NotebookStorageError.invalidTransaction("non-notebook page selection") }
    }
    try savePresence(presence.selecting(itemID: itemID, pageID: index.selectedPageID))
  }

  private func pageAppendWorkspace() throws -> (NotebookStoredFragment, UUID, VersionStamp) {
    guard let database = currentSQL, database.writable,
      let root = try storedFragments(address: "workspace.json#", descendants: false).first,
      root.value["format"] == .number(Double(WorkspaceIndex.formatVersion)),
      let rootBoardID = root.value["rootBoardID"]?.string.flatMap(UUID.init(uuidString:)),
      let stamp = try root.value["stamp"]?.decode(VersionStamp.self),
      stamp.counter <= VersionStamp.maximumCounter else {
      throw NotebookStorageError.invalidTransaction("page landing workspace")
    }
    return (root, rootBoardID, stamp)
  }

  private func pageAppendVersions(keys: [String]) throws -> [ContentFieldVersion?] {
    try keys.map { key in
      let version = try storedFragments(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), descendants: false).first?.value.decode(ContentFieldVersion.self)
      guard version?.isValid != false else { throw NotebookStorageError.corruptRecord("page append causal field") }
      return version
    }
  }
}
