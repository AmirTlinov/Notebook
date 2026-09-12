import Foundation
import NotebookCore

extension CodexAppServer {
  static func availableAccess(_ rpc: CodexRPC, cwd: String?) async throws -> [CodexAccessMode] {
    var cursor: String?, modes: [CodexAccessMode] = []
    // The UI offers the built-in levels; custom profiles remain visible as the
    // native selection, never silently converted to one of these presets.
    for _ in 0..<4 {
      var params: [String: JSONValue] = ["limit": .number(32)]
      if let cwd { params["cwd"] = .string(cwd) }
      if let cursor { params["cursor"] = .string(cursor) }
      let reply = try await rpc.request("permissionProfile/list", params: .object(params))
      guard let rows = reply["data"]?.array, rows.count <= 32 else { throw CodexBridgeError.invalidResponse }
      for row in rows where row["allowed"] == .bool(true) {
        if let id = row["id"]?.string, let mode = CodexAccessMode(rawValue: id), !modes.contains(mode) { modes.append(mode) }
      }
      guard let next = reply["nextCursor"]?.string else { return CodexAccessMode.allCases.filter(modes.contains) }
      guard next != cursor else { throw CodexBridgeError.invalidResponse }; cursor = next
    }
    throw CodexBridgeError.historyLimit
  }
}
