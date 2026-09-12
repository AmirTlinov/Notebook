import Foundation
import NotebookCore

extension CodexAppServer {
  public func models() async throws -> [CodexModelOption] {
    try await session { rpc in try await Self.models(rpc) }
  }
  static func models(_ rpc: CodexRPC) async throws -> [CodexModelOption] {
    var result: [CodexModelOption] = [], cursor: String?
    for _ in 0..<4 {
      var params: [String: JSONValue] = ["limit": .number(32), "includeHidden": .bool(false)]
      if let cursor { params["cursor"] = .string(cursor) }
      let reply = try await rpc.request("model/list", params: .object(params))
      guard let rows = reply["data"]?.array, rows.count <= 32 else { throw CodexBridgeError.invalidResponse }
      result += try rows.filter { $0["hidden"] != .bool(true) }.map(Self.modelOption)
      guard let next = reply["nextCursor"]?.string else { return result }
      guard next != cursor else { throw CodexBridgeError.invalidResponse }; cursor = next
    }
    throw CodexBridgeError.historyLimit
  }
  static func modelOption(_ row: JSONValue) throws -> CodexModelOption {
    guard let id = row["model"]?.string, !id.isEmpty, id.utf8.count <= 256,
      let name = row["displayName"]?.string, let effort = row["defaultReasoningEffort"]?.string,
      let options = row["supportedReasoningEfforts"]?.array, options.count <= 16 else { throw CodexBridgeError.invalidResponse }
    let efforts = options.compactMap { $0["reasoningEffort"]?.string }
    guard efforts.count == options.count, efforts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 }) else { throw CodexBridgeError.invalidResponse }
    return .init(id: id, name: String(name.prefix(128)), efforts: efforts, defaultEffort: effort, isDefault: row["isDefault"] == .bool(true))
  }

  public func resources(threadID: String, kind: CodexResourceKind, cursor: String?) async throws -> CodexResourcePage {
    guard UUID(uuidString: threadID) != nil else { throw CodexBridgeError.invalidInput }
    return try await session { rpc in
      if kind == .apps {
        // The add menu lists installed callable apps, not the remote store. Reading
        // the whole directory can wait on a network catalogue unrelated to this draft.
        let installed = try await rpc.request("app/installed", params: .object(["threadId": .string(threadID), "forceRefresh": .bool(false)]))
        guard let apps = installed["apps"]?.array, apps.count <= 4096 else { throw CodexBridgeError.invalidResponse }
        let offset = cursor.flatMap(Int.init) ?? 0
        guard cursor == nil || Int(cursor!) != nil, offset >= 0, offset <= apps.count else { throw CodexBridgeError.invalidInput }
        let rows = Array(apps.dropFirst(offset).prefix(32)), ids = rows.compactMap { $0["id"]?.string }
        guard ids.count == rows.count else { throw CodexBridgeError.invalidResponse }
        if ids.isEmpty { return .init(resources: []) }
        let metadata = try await rpc.request("app/read", params: .object(["appIds": .array(ids.map(JSONValue.string)), "includeTools": .bool(false)]))
        let descriptions = metadata["apps"]?.array ?? []
        return .init(resources: try rows.map { row in
          guard let id = row["id"]?.string else { throw CodexBridgeError.invalidResponse }
          let info = descriptions.first { $0["id"] == .string(id) }
          let name = info?["name"]?.string ?? row["runtimeName"]?.string ?? id
          return Self.resource(kind: .app, name: name, path: "app://" + id, title: name,
            detail: info?["description"]?.string, enabled: row["enabled"] == .bool(true) && row["callable"] == .bool(true))
        }, nextCursor: offset + rows.count < apps.count ? String(offset + rows.count) : nil)
      }
      // Resolve cwd from the real thread, including worktrees; never from an iPad-supplied path.
      let thread = try await rpc.request("thread/read", params: .object(["threadId": .string(threadID), "includeTurns": .bool(false)]))
      guard let cwd = thread["thread"]?["cwd"]?.string else { throw CodexBridgeError.invalidResponse }
      let reply = try await rpc.request(kind == .skills ? "skills/list" : "plugin/installed", params: .object(["cwds": .array([.string(cwd)])]))
      let rows: [JSONValue], notice: String?
      if kind == .skills {
        guard let entry = reply["data"]?.array?.first, let skills = entry["skills"]?.array else { throw CodexBridgeError.invalidResponse }
        rows = skills; notice = entry["errors"]?.array?.isEmpty == false ? "Некоторые навыки не удалось прочитать в Codex." : nil
      } else {
        guard let markets = reply["marketplaces"]?.array else { throw CodexBridgeError.invalidResponse }
        rows = markets.flatMap { $0["plugins"]?.array ?? [] }.filter { $0["installed"] == .bool(true) }
        notice = reply["marketplaceLoadErrors"]?.array?.isEmpty == false ? "Некоторые каталоги плагинов недоступны в Codex." : nil
      }
      let offset = cursor.flatMap(Int.init) ?? 0
      guard cursor == nil || Int(cursor!) != nil, offset >= 0, offset <= rows.count, rows.count <= 4096 else { throw CodexBridgeError.invalidInput }
      let page = try rows.dropFirst(offset).prefix(32).map { row -> CodexComposerResource in
        guard let name = row["name"]?.string, let path = kind == .skills ? row["path"]?.string : row["id"]?.string.map({ "plugin://" + $0 }) else { throw CodexBridgeError.invalidResponse }
        return Self.resource(kind: kind == .skills ? .skill : .plugin, name: name, path: path,
          title: row["interface"]?["displayName"]?.string ?? name,
          detail: row["interface"]?["shortDescription"]?.string ?? row["description"]?.string,
          enabled: row["enabled"] == .bool(true) && row["availability"] != .string("DISABLED_BY_ADMIN"))
      }
      guard page.allSatisfy({ $0.attachment.isValid }) else { throw CodexBridgeError.invalidResponse }
      return .init(resources: page, nextCursor: offset + page.count < rows.count ? String(offset + page.count) : nil, notice: notice)
    }
  }
  private static func resource(kind: CodexInputAttachment.Kind, name: String, path: String, title: String, detail: String?, enabled: Bool) -> CodexComposerResource {
    .init(attachment: .init(kind: kind, name: String(name.prefix(128)), path: path), title: String(title.prefix(128)), detail: String((detail ?? "").prefix(240)), enabled: enabled)
  }

  static func composerInput(text: String, attachments: [CodexInputAttachment]) throws -> [JSONValue] {
    guard CodexInputAttachment.valid(attachments) else { throw CodexBridgeError.invalidInput }
    // Files remain references to the Mac working copy, not snapshots secretly uploaded into the prompt.
    let paths = attachments.filter { $0.kind == .file || $0.kind == .folder }.map { $0.path }
    let names = attachments.filter { $0.kind != .file && $0.kind != .folder }.map { ($0.kind == .plugin ? "@" : "$") + $0.name }
    let message = text + (names.isEmpty ? "" : "\n\n" + names.joined(separator: " "))
      + (paths.isEmpty ? "" : "\n\nФайлы и папки:\n" + paths.joined(separator: "\n"))
    return [.textInput(message)] + attachments.map { .object([
      "type": .string($0.kind == .skill ? "skill" : "mention"), "name": .string($0.name), "path": .string($0.path)]) }
  }
}
