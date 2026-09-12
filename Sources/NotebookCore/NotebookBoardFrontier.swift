import CryptoKit
import Foundation

extension NotebookStore {
  /// The completed content of this physical board, including every placement
  /// head and element outside a bounded scene window. Spatial ink and the
  /// portal camera have independent owners and never change this precondition.
  /// The maintained row digest is already current inside the publishing command;
  /// only its one fixed-size header contribution needs a content-only projection.
  public func boardContentRevision(_ id: UUID) throws -> String? {
    try sqlRead { database in
      let key = id.uuidString.lowercased()
      let address = "board.json#/boards/@" + key
      guard let row = try database.rows("""
        SELECT d.digest,r.hash,b.data FROM records r
        LEFT JOIN board_nodes d ON d.node_id=? LEFT JOIN blobs b ON b.hash=r.hash
        WHERE r.address=?
        """, [.text(key), .text(address)]).first else { return nil }
      guard var digest = row[0].blob, digest.count == 32, let hash = row[1].text, let data = row[2].blob else {
        throw NotebookStorageError.corruptRecord(address)
      }
      guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
        throw NotebookStorageError.blobHashMismatch
      }
      let header = try JSONDecoder().decode(NotebookStoredFragment.self, from: data)
      guard header.address == address, case .object? = header.value["board"] else {
        throw NotebookStorageError.corruptRecord(address)
      }
      let content = header.replacing(value: header.value.setting("portalCamera", nil).setting("portalStamp", nil))
      let contentHash = SHA256.hash(data: try Self.storageEncoder.encode(content))
        .map { String(format: "%02x", $0) }.joined()
      for hash in [hash, contentHash] {
        for (offset, byte) in Self.boardRowContribution(address: address, hash: hash).enumerated() { digest[offset] ^= byte }
      }
      return SHA256.hash(data: Data(("board-content-v1\n" + key + "\n").utf8) + digest)
        .map { String(format: "%02x", $0) }.joined()
    }
  }

  private static func boardNodeRevision(id: String, digest: Data) -> String {
    SHA256.hash(data: Data(("board-node-v1\n" + id + "\n").utf8) + digest)
      .map { String(format: "%02x", $0) }.joined()
  }

  private static func boardRowContribution(address: String, hash: String) -> SHA256.Digest {
    SHA256.hash(data: Data(("board-row-v1\n" + address + "\n" + hash).utf8))
  }

  /// Each row contributes a domain-separated digest to its one physical board.
  /// A changed board then updates a bounded UUID radix path. No read of other
  /// board bodies or catalogue members participates in a scene identity.
  func updateBoardContribution(address: String, previous: String?, next: String?, database: NotebookSQLConnection) throws {
    let prefix = "board.json#/boards/@"
    guard address.hasPrefix(prefix), let component = address.dropFirst(prefix.count).split(separator: "/").first,
      let id = UUID(uuidString: String(component)) else { return }
    let node = id.uuidString.lowercased()
    var digest = try database.rows("SELECT digest FROM board_nodes WHERE node_id=?", [.text(node)]).first?[0].blob ?? Data(repeating: 0, count: 32)
    for hash in [previous, next].compactMap({ $0 }) {
      let contribution = Self.boardRowContribution(address: address, hash: hash)
      for (offset, byte) in contribution.enumerated() { digest[offset] ^= byte }
    }
    try database.run("INSERT INTO board_nodes(node_id,digest) VALUES(?,?) ON CONFLICT(node_id) DO UPDATE SET digest=excluded.digest", [.text(node), .blob(digest)])
    try database.noteOwner(.board, node)
  }

  func refreshBoardFrontier(database: NotebookSQLConnection) throws {
    guard try database.hasOwner(.board) || database.hasChange("board.json#") else { return }
    try database.visitOwners(.board) { id in
      let key = id.replacingOccurrences(of: "-", with: "")
      let rootExists = try !database.rows("SELECT 1 FROM records WHERE address=?", [.text("board.json#/boards/@" + id)]).isEmpty
      if rootExists, let digest = try database.rows("SELECT digest FROM board_nodes WHERE node_id=?", [.text(id)]).first?[0].blob {
        let hash = Self.boardNodeRevision(id: id, digest: digest)
        try database.run("INSERT INTO board_frontier(prefix,parent,hash) VALUES(?,?,?) ON CONFLICT(prefix) DO UPDATE SET hash=excluded.hash", [.text(key), .text(String(key.dropLast())), .text(hash)])
      } else {
        try database.run("DELETE FROM board_frontier WHERE prefix=?", [.text(key)])
        try database.run("DELETE FROM board_nodes WHERE node_id=?", [.text(id)])
      }
      for length in 0..<32 { try database.noteOwner(.boardPrefix, String(format: "%02d:", length) + key.prefix(length)) }
    }
    try database.visitOwners(.boardPrefix, descending: true) { encoded in
      let prefix = String(encoded.dropFirst(3))
      let children = try database.rows("SELECT prefix,hash FROM board_frontier WHERE parent=? ORDER BY prefix", [.text(prefix)])
      if children.isEmpty { try database.run("DELETE FROM board_frontier WHERE prefix=?", [.text(prefix)]) }
      else {
        let source = children.map { $0[0].text! + ":" + $0[1].text! }.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(("board-radix-v1\n" + source).utf8)).map { String(format: "%02x", $0) }.joined()
        try database.run("INSERT INTO board_frontier(prefix,parent,hash) VALUES(?,?,?) ON CONFLICT(prefix) DO UPDATE SET hash=excluded.hash", [.text(prefix), prefix.isEmpty ? .null : .text(String(prefix.dropLast())), .text(hash)])
      }
    }
    let treeHash = try database.rows("SELECT hash FROM board_frontier WHERE prefix=''").first?[0].text ?? ""
    let rootHash = try database.rows("SELECT hash FROM records WHERE address='board.json#'").first?[0].text ?? ""
    let revision = SHA256.hash(data: Data(("board-scene-v1\n" + rootHash + "\n" + treeHash).utf8)).map { String(format: "%02x", $0) }.joined()
    try database.run("INSERT INTO metadata(key,value) VALUES('board_revision',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(revision)])
  }
}
