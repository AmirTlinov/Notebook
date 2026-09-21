import CryptoKit
import Foundation

extension NotebookStore {
  /// Pencil owns the drawing stream, not the page's elements or their clocks.
  /// Join that stream through the ordinary page merge and physical row writer,
  /// without decoding/encoding unrelated graphics, programs or causal fields.
  public func savePageInk(pageID: UUID, data: Data, stamp: VersionStamp) throws
    -> (data: Data, stamp: VersionStamp) {
    try commandTransaction {
      if try hasStoredValue("workspace.json"), try ownerItemID(ofPage: pageID) == nil {
        throw CocoaError(.fileNoSuchFile)
      }
      let file = pageFile(pageID), address = file + "#/drawingData", database = currentSQL!
      guard let header = try storedFragments(address: file + "#", descendants: false).first,
        try header.value["id"]?.decode(UUID.self) == pageID,
        header.value["format"] == .number(Double(PageDocument.formatVersion)),
        let size = try header.value["size"]?.decode(PageSize.self),
        size.isValid,
        let previousStamp = try header.value["drawingStamp"]?.decode(VersionStamp.self),
        previousStamp.counter <= VersionStamp.maximumCounter
      else { throw NotebookStorageError.corruptRecord(file) }
      let rows = try storedFragments(address: address, descendants: true)
      let drawing = try NotebookRecordCodec.decode(rows, root: address).decode(PageInkDrawing.self)
      let previousData = try drawing.dataRepresentation()
      var ink = PageDocument(id: pageID, size: size, actor: previousStamp.actor,
        drawingData: previousData)
      _ = try ink.mergeDrawing(previousData, stamp: previousStamp)
      _ = try ink.mergeDrawing(data, stamp: stamp)
      if ink.drawingData == previousData && ink.drawingStamp == previousStamp {
        return (previousData, previousStamp)
      }
      if ink.drawingData != previousData {
        let accepted = try PageInkDrawing.decode(ink.drawingData)
        let fragments = try NotebookRecordCodec.encode(.encode(accepted), file: file,
          address: address, parent: file + "#", collection: "drawingData")
        var old = Dictionary(uniqueKeysWithValues: try database.rows(
          "SELECT address,hash FROM records WHERE address=? OR (address>=? AND address<?)",
          [.text(address), .text(address + "/"), .text(address + "/\u{10ffff}")]
        ).map { ($0[0].text!, $0[1].text!) })
        for fragment in fragments {
          let bytes = try database.encodedStoredFragment(fragment)
          let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
          if old.removeValue(forKey: fragment.address) == hash { continue }
          try writeFragment(fragment, data: bytes, hash: hash, database: database)
        }
        for stale in old.keys { try removeFragment(stale, database: database) }
      }
      try writeFragment(header.replacing(value: header.value.setting("drawingStamp", .encode(ink.drawingStamp))),
        database: database)
      return (ink.drawingData, ink.drawingStamp)
    }
  }
}
