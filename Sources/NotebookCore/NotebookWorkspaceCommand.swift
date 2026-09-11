import Foundation

extension NotebookStore {
  /// A landing names an existing physical notebook, not a replacement catalog.
  /// Only the new UUID and its causal fields are read from the UI projection.
  func publishPageLanding(index: WorkspaceIndex, createdPage: PageDocument?) throws {
    guard let database = currentSQL, database.writable,
      index.format == WorkspaceIndex.formatVersion,
      let root = try storedFragments(address: "workspace.json#", descendants: false).first,
      root.value["format"] == .number(Double(WorkspaceIndex.formatVersion)),
      root.value["rootBoardID"]?.string.flatMap(UUID.init(uuidString:)) == index.rootBoardID,
      let currentStamp = try root.value["stamp"]?.decode(VersionStamp.self),
      currentStamp.counter <= VersionStamp.maximumCounter,
      index.stamp.counter <= VersionStamp.maximumCounter else {
      throw NotebookStorageError.invalidTransaction("page landing workspace")
    }
    guard try hasStoredValue(at: presenceURL) else {
      throw CollaborationError("dependency_missing", "Выбор листа требует подготовленного присутствия устройства.")
    }
    let presence = try loadPresence()
    let itemID = index.selectedItemID, item = itemID.uuidString.lowercased()
    let itemAddress = "workspace.json#/items/@" + item
    guard let storedItem = try storedFragments(address: itemAddress, descendants: false).first,
      let kind = storedItem.value["kind"]?.string.flatMap(WorkspaceItemKind.init(rawValue:)) else {
      throw CocoaError(.fileNoSuchFile)
    }
    if let page = createdPage {
      guard kind == .notebook, index.selectedPageID == page.id,
        index.item(id: itemID)?.pageIDs.last == page.id, page.isValid else {
        throw NotebookStorageError.invalidTransaction("page append identity")
      }
      let pageID = page.id.uuidString.lowercased()
      let pageAddress = itemAddress + "/pageIDs/@" + pageID
      let keys = [fieldKey(["items", item, "exists"]), fieldKey(["items", item, "pageIDs"]),
        fieldKey(["items", item, "pageIDs", pageID])]
      var authored: [ContentFieldVersion] = [], previous: [ContentFieldVersion?] = []
      for key in keys {
        guard let version = index.collaboration.fields[key], version.isValid, version.human else {
          throw NotebookStorageError.invalidTransaction("page append causal field")
        }
        authored.append(version)
        let old = try storedFragments(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), descendants: false).first?.value.decode(ContentFieldVersion.self)
        guard old?.isValid != false else { throw NotebookStorageError.corruptRecord("page append causal field") }
        previous.append(old)
      }
      let owner = try ownerItemID(ofPage: page.id)
      guard owner == nil || owner == itemID else { throw NotebookStorageError.invalidTransaction("page already belongs to another notebook") }
      let existing = try storedFragments(address: pageAddress, descendants: false).first
      let currentOrder = try readPageOrder(itemID)
      // Membership tombstones are not reusable UUID reservations. A retry of
      // an already committed append has its live membership; a deleted one does not.
      guard existing != nil || previous[2] == nil else { throw CocoaError(.fileNoSuchFile) }
      if existing == nil {
        let maximum = try database.rows("SELECT COALESCE(MAX(position),-1) FROM records INDEXED BY record_order WHERE parent=? AND collection='pageIDs'", [.text(itemAddress)]).first![0].integer!
        guard maximum >= 0, maximum < Int64.max else { throw NotebookStorageError.limitExceeded("page_sequence") }
        try writeFragment(.init(address: pageAddress, file: "workspace.json", parent: itemAddress,
          collection: "pageIDs", member: pageID, position: Int(maximum + 1), value: .string(page.id.uuidString), collections: []), database: database)
      }
      _ = try savePage(page)
      var frontier = max(currentStamp, index.stamp)
      for version in previous.compactMap({ $0 }) { frontier = max(frontier, version.stamp) }
      // Append is executed at the current tail. If another accepted catalog
      // edit overtook this projection, the sequence adopts that durable cut;
      // the caller's original page UUID and its birth version remain unchanged.
      if existing == nil, frontier >= index.stamp, currentStamp >= index.stamp {
        guard let advanced = frontier.advanced(by: authored[2].stamp.actor) else { throw NotebookStorageError.limitExceeded("workspace clock") }
        frontier = advanced
      }
      let nextOrder: NotebookPageOrderRegister
      if existing == nil {
        let nextRoot = try NotebookPageOrderVector.append(to: currentOrder.visibleRoot, pageID: page.id,
          read: { try readPageOrderNode($0) }, write: { try writePageOrderNode($0) })
        nextOrder = try .authored(root: nextRoot, stamp: frontier, human: true, previous: currentOrder)
        try writePageOrder(nextOrder, itemID: itemID)
      } else { nextOrder = currentOrder }
      for (offset, key) in keys.enumerated() {
        let joined = previous[offset].map { $0.joining(authored[offset]) } ?? authored[offset]
        let version = offset == 1 ? nextOrder.fieldVersion : existing == nil && offset == 0
          ? ContentFieldVersion(stamp: frontier, human: true, previous: joined) : joined
        guard version.isValid else { throw NotebookStorageError.limitExceeded("page append causal actors") }
        if version != previous[offset] {
          try writeFragment(.init(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), file: "workspace.json",
            parent: "workspace.json#", collection: "collaboration/fields", member: key, position: 0,
            value: try .encode(version), collections: []), database: database)
        }
      }
      if frontier != currentStamp { try writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(frontier))), database: database) }
    } else if kind == .notebook {
      guard let pageID = index.selectedPageID, try ownerItemID(ofPage: pageID) == itemID,
        try hasStoredValue(pageFile(pageID)) else { throw CocoaError(.fileNoSuchFile) }
    } else if index.selectedPageID != nil {
      throw NotebookStorageError.invalidTransaction("non-notebook page selection")
    }
    try savePresence(presence.selecting(itemID: itemID, pageID: index.selectedPageID))
  }
}
