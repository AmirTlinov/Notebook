import Foundation
import NotebookCore

public enum CodexBridgeError: String, Error, Sendable {
  case notInstalled, incompatibleVersion, unsafeEndpoint, unavailable, disconnected, timeout
  case invalidFrame, invalidResponse, requestRejected, historyLimit, busy, staleTurn
  case staleRequest, unsupportedRequest, invalidInput, acceptanceUnknown, signInRequired, externalOwnerUnavailable
}

enum CodexProtocol {
  static let frameLimit = 8 * 1_048_576
  static let messageLimit = 32_768
}

extension JSONValue {
  var string: String? { if case .string(let v) = self { v } else { nil } }
  var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
  var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
  var integer: Int? {
    guard case .number(let v) = self, v.isFinite, v >= 0, v <= 9_007_199_254_740_991, v.rounded() == v else { return nil }
    return Int(v)
  }
  static func textInput(_ text: String) -> JSONValue {
    .object(["type": .string("text"), "text": .string(text), "text_elements": .array([])])
  }
}

extension CodexAppServerState {
  static func displayMessage(_ item: JSONValue, turnID: String) -> CodexMessage? {
    guard let id = item["id"]?.string, let type = item["type"]?.string else { return nil }
    let role: CodexMessage.Role, text: String
    var activity: CodexMessage.Activity?
    var attachments: [String]?
    var detailTruncated = false
    let status = item["status"]?.string
    func action(_ kind: CodexMessage.Activity.Kind, _ detail: String? = nil) -> CodexMessage.Activity {
      detailTruncated = detailTruncated || (detail?.count ?? 0) > 8192
      return .init(kind: kind, status: status, detail: detail.map { String($0.prefix(8192)) })
    }
    func pretty(_ value: JSONValue?) -> String? {
      guard let value, value != .null else { return nil }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return try? String(decoding: encoder.encode(value), as: UTF8.self)
    }
    switch type {
    case "userMessage":
      guard item["content"] != nil else { return nil }
      role = .user
      let raw = (item["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
      let display = CodexUserMessageDisplay(raw)
      text = display.text; attachments = display.attachments.isEmpty ? nil : display.attachments
    case "agentMessage":
      role = .assistant; text = item["text"]?.string ?? ""
    case "commandExecution":
      role = .assistant
      let command = item["command"]?.string ?? ""
      text = (status == "inProgress" ? "Выполняется команда" : status == "failed" ? "Команда завершилась ошибкой" : "Выполнена команда") + (command.isEmpty ? "" : " · " + String(command.prefix(160)))
      let output = item["aggregatedOutput"]?.string
      activity = action(.command, command + (output.map { "\n\n" + $0 } ?? ""))
    case "fileChange":
      role = .assistant
      let changes = item["changes"]?.array ?? []
      text = (status == "inProgress" ? "Изменяются файлы" : "Изменены файлы") + " · \(changes.count)"
      activity = action(.files, changes.compactMap { change in
        change["path"]?.string.map { $0 + (change["diff"]?.string.map { "\n" + $0 } ?? "") }
      }.joined(separator: "\n\n"))
    case "mcpToolCall", "dynamicToolCall", "functionCallOutput":
      role = .assistant
      let name = [item["server"]?.string ?? item["namespace"]?.string, item["tool"]?.string ?? item["name"]?.string].compactMap { $0 }.joined(separator: ".")
      text = (status == "inProgress" ? "Инструмент работает" : status == "failed" ? "Ошибка инструмента" : "Вызван инструмент") + (name.isEmpty ? "" : " · " + name)
      activity = action(.tool, [pretty(item["arguments"]), pretty(item["error"] ?? item["result"])].compactMap { $0 }.joined(separator: "\n\n"))
    case "webSearch":
      role = .assistant; text = "Поиск · " + (item["query"]?.string ?? ""); activity = action(.search)
    case "imageView":
      role = .assistant; text = "Просмотрено изображение"; activity = action(.image, item["path"]?.string)
    case "plan", "planImplementation":
      role = .assistant; text = "План работы"; activity = action(.plan, item["text"]?.string)
    case "contextCompaction":
      role = .assistant; text = item["completed"] == .bool(false) ? "Контекст сжимается" : "Контекст сжат"; activity = action(.compaction)
    case "error":
      role = .assistant; text = "Ошибка Codex"; activity = action(.error, item["message"]?.string)
    // Reasoning content, hidden context and optimistic/steering input are not a
    // second transcript. Canonical user items and public commentary own those rows.
    default: return nil
    }
    return CodexMessage(id: id, turnID: turnID, clientID: item["clientId"]?.string, role: role,
      text: String(text.prefix(16_384)), isTruncated: text.count > 16_384 || detailTruncated, activity: activity, attachments: attachments)
  }
}
