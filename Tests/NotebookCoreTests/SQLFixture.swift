import Foundation
@testable import NotebookCore

extension NotebookStore {
  /// Test-only corruption injection addresses the canonical SQL record; no
  /// JSON path is a second production owner in the new format.
  func fixtureWrite(_ data: Data, to url: URL) throws {
    let value = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .string("deliberately damaged typed owner")
    let file = logicalAddress(url)
    try commandTransaction {
      let database = currentSQL!
      try database.run("DELETE FROM records WHERE file=?", [.text(file)])
      for fragment in try NotebookRecordCodec.encode(value, file: file) {
        let hash = try database.putBlob(Self.storageEncoder.encode(fragment))
        try database.run("INSERT INTO records(address,file,parent,collection,member,position,hash) VALUES(?,?,?,?,?,?,?)", [
          .text(fragment.address), .text(file), fragment.parent.map(NotebookSQLValue.text) ?? .null,
          .text(fragment.collection), .text(fragment.member), .integer(Int64(fragment.position)), .text(hash)])
      }
    }
  }
}
