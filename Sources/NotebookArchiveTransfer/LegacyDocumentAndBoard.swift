import Foundation
import NotebookCore

private struct ArchiveFormat: Decodable { let format: Int }
private func archiveObject(_ data: Data) throws -> [String: Any] {
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw ArchiveTransferError.invalidSource("expected an archived object")
  }
  return object
}
private func archiveData(_ object: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// Paper size did not exist in Document/1. Only the offline converter assigns
/// its published A4 meaning; a live decoder never guesses missing ownership.
func convertLegacyDocument(_ data: Data) throws -> DocumentDocument {
  let format = try JSONDecoder().decode(ArchiveFormat.self, from: data).format
  guard format == 1 else { return try JSONDecoder().decode(DocumentDocument.self, from: data).materializingCausalVersions() }
  var object = try archiveObject(data)
  object["format"] = DocumentDocument.formatVersion
  object["paperSize"] = DocumentPaperSize.a4.rawValue
  return try JSONDecoder().decode(DocumentDocument.self, from: archiveData(object)).materializingCausalVersions()
}

/// The retired board named placements by notebookID. Rename only those typed
/// fields: element/program state with similar names remains original content.
func convertLegacyBoard(_ data: Data) throws -> BoardDocument {
  let format = try JSONDecoder().decode(ArchiveFormat.self, from: data).format
  guard format == 1 else { return try JSONDecoder().decode(BoardDocument.self, from: data) }
  var object = try archiveObject(data)
  guard let free = object.removeValue(forKey: "freeNotebooks") as? [[String: Any]],
    let stacks = object["stacks"] as? [[String: Any]] else {
    throw ArchiveTransferError.invalidSource("Board/1 requires placements and stacks")
  }
  object["freeItems"] = try free.map { original in
    var item = original
    guard let id = item.removeValue(forKey: "notebookID") else {
      throw ArchiveTransferError.invalidSource("Board/1 placement requires notebookID")
    }
    item["itemID"] = id
    return item
  }
  object["stacks"] = try stacks.map { original in
    var stack = original
    guard let ids = stack.removeValue(forKey: "notebookIDs") else {
      throw ArchiveTransferError.invalidSource("Board/1 stack requires notebookIDs")
    }
    stack["itemIDs"] = ids
    return stack
  }
  object["format"] = BoardDocument.formatVersion
  return try JSONDecoder().decode(BoardDocument.self, from: archiveData(object))
}

func convertLegacyHierarchy(_ data: Data) throws -> BoardHierarchy {
  var object = try archiveObject(data)
  guard let nodes = object["boards"] as? [[String: Any]] else {
    throw ArchiveTransferError.invalidSource("archived hierarchy requires board nodes")
  }
  object["boards"] = try nodes.map { original in
    var node = original
    guard let board = node["board"] as? [String: Any] else {
      throw ArchiveTransferError.invalidSource("archived node requires a board")
    }
    let converted = try convertLegacyBoard(archiveData(board))
    node["board"] = try archiveObject(JSONEncoder().encode(converted))
    // Before portals, an absent camera meant the origin at scale one and its
    // clock belonged to this board's actor. Explicit malformed values still fail.
    if node["portalCamera"] == nil {
      node["portalCamera"] = try archiveObject(JSONEncoder().encode(BoardPortalCamera()))
    }
    if node["portalStamp"] == nil {
      node["portalStamp"] = try archiveObject(JSONEncoder().encode(VersionStamp(counter: 0, actor: converted.stamp.actor)))
    }
    return node
  }
  return try JSONDecoder().decode(BoardHierarchy.self, from: archiveData(object))
}
