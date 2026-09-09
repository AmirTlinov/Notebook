import CryptoKit
import Foundation

extension NotebookStore {
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
      let contribution = SHA256.hash(data: Data(("board-row-v1\n" + address + "\n" + hash).utf8))
      for (offset, byte) in contribution.enumerated() { digest[offset] ^= byte }
    }
    try database.run("INSERT INTO board_nodes(node_id,digest) VALUES(?,?) ON CONFLICT(node_id) DO UPDATE SET digest=excluded.digest", [.text(node), .blob(digest)])
    database.dirtyBoardNodes.insert(node)
  }

  func refreshBoardFrontier(database: NotebookSQLConnection) throws {
    guard !database.dirtyBoardNodes.isEmpty || database.changes["board.json#"] != nil else { return }
    var levels: [Int: Set<String>] = [:]
    for id in database.dirtyBoardNodes {
      let key = id.replacingOccurrences(of: "-", with: "")
      let rootExists = try !database.rows("SELECT 1 FROM records WHERE address=?", [.text("board.json#/boards/@" + id)]).isEmpty
      if rootExists, let digest = try database.rows("SELECT digest FROM board_nodes WHERE node_id=?", [.text(id)]).first?[0].blob {
        let hash = SHA256.hash(data: Data(("board-node-v1\n" + id + "\n").utf8) + digest).map { String(format: "%02x", $0) }.joined()
        try database.run("INSERT INTO board_frontier(prefix,parent,hash) VALUES(?,?,?) ON CONFLICT(prefix) DO UPDATE SET hash=excluded.hash", [.text(key), .text(String(key.dropLast())), .text(hash)])
      } else {
        try database.run("DELETE FROM board_frontier WHERE prefix=?", [.text(key)])
        try database.run("DELETE FROM board_nodes WHERE node_id=?", [.text(id)])
      }
      for length in 0..<32 { levels[length, default: []].insert(String(key.prefix(length))) }
    }
    for length in stride(from: 31, through: 0, by: -1) {
      for prefix in levels[length] ?? [] {
        let children = try database.rows("SELECT prefix,hash FROM board_frontier WHERE parent=? ORDER BY prefix", [.text(prefix)])
        if children.isEmpty { try database.run("DELETE FROM board_frontier WHERE prefix=?", [.text(prefix)]) }
        else {
          let source = children.map { $0[0].text! + ":" + $0[1].text! }.joined(separator: "\n")
          let hash = SHA256.hash(data: Data(("board-radix-v1\n" + source).utf8)).map { String(format: "%02x", $0) }.joined()
          try database.run("INSERT INTO board_frontier(prefix,parent,hash) VALUES(?,?,?) ON CONFLICT(prefix) DO UPDATE SET hash=excluded.hash", [.text(prefix), prefix.isEmpty ? .null : .text(String(prefix.dropLast())), .text(hash)])
        }
      }
    }
    let treeHash = try database.rows("SELECT hash FROM board_frontier WHERE prefix=''").first?[0].text ?? ""
    let rootHash = try database.rows("SELECT hash FROM records WHERE address='board.json#'").first?[0].text ?? ""
    let revision = SHA256.hash(data: Data(("board-scene-v1\n" + rootHash + "\n" + treeHash).utf8)).map { String(format: "%02x", $0) }.joined()
    try database.run("INSERT INTO metadata(key,value) VALUES('board_revision',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(revision)])
  }
}
