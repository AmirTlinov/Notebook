import Foundation
import NotebookCore

/// The workspace runtime inherits the user's Codex policy without changing it.
enum CodexNotebookToolPolicy: Error, LocalizedError {
  case disabled
  var errorDescription: String? {
    switch self {
    case .disabled: "Notebook отключён в конфигурации Codex (mcp_servers.notebook.enabled=false). Включите его в настройках Codex, если хотите разрешить интеграцию. Настройки не изменены."
    }
  }
  static func requireEnabled(_ entry: JSONValue?) throws {
    if entry?["enabled"] == .bool(false) { throw Self.disabled }
  }
  static func scoped(_ endpoint: JSONValue, inheriting effective: JSONValue) throws -> JSONValue {
    guard let config = effective["config"]?.object, let endpoint = endpoint.object else { throw CodexBridgeError.invalidResponse }
    let inherited = config["mcp_servers"]?["notebook"]
    try requireEnabled(inherited)
    // config/read represents unset optional values as JSON null. Passing those
    // through thread/start turns them into invalid explicit config overrides.
    var result = (inherited?.object ?? [:]).filter { $0.value != .null }
    // Do not forward another transport's credentials or working directory.
    for key in ["url", "bearer_token_env_var", "http_headers", "env_http_headers", "env_vars", "cwd"] { result.removeValue(forKey: key) }
    for (key, value) in endpoint { result[key] = value }
    return .object(result)
  }
}
