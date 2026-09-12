import Foundation

/// A projection of Codex's catalogue, not Notebook's choice of available models.
public struct CodexModelOption: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let efforts: [String]
  public let defaultEffort: String
  public let isDefault: Bool
  public init(id: String, name: String, efforts: [String], defaultEffort: String, isDefault: Bool = false) {
    self.id = id; self.name = name; self.efforts = efforts; self.defaultEffort = defaultEffort; self.isDefault = isDefault
  }
}

public struct CodexModelSelection: Codable, Equatable, Sendable {
  public let model: String
  public let effort: String?
  public init(model: String, effort: String?) { self.model = model; self.effort = effort }
  public var isValid: Bool { !model.isEmpty && model.utf8.count <= 256 && (effort?.utf8.count ?? 0) <= 32 }
}

/// Last native context usage, never accumulated billing usage or a text-length estimate.
public struct CodexContextUsage: Codable, Equatable, Sendable {
  public let used: Int
  public let window: Int?
  public init(used: Int, window: Int?) { self.used = used; self.window = window }
  public var fraction: Double? {
    guard used >= 0, let window, window > 0 else { return nil }
    return min(1, Double(used) / Double(window))
  }
}

public struct CodexInputAttachment: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable { case file, folder, skill, plugin, app }
  public let kind: Kind
  public let name: String
  public let path: String
  public var id: String { kind.rawValue + ":" + path }
  public init(kind: Kind, name: String, path: String) { self.kind = kind; self.name = name; self.path = path }
  public var isValid: Bool {
    guard !name.isEmpty, name.utf8.count <= 256, path.utf8.count <= 4096,
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
    switch kind {
    case .file, .folder, .skill: return path.hasPrefix("/") && URL(fileURLWithPath: path).standardizedFileURL.path == path
    case .plugin: return path.hasPrefix("plugin://") && path.count > 9
    case .app: return path.hasPrefix("app://") && path.count > 6
    }
  }
  public static func valid(_ values: [Self]) -> Bool {
    values.count <= 16 && values.allSatisfy(\.isValid) && Set(values.map(\.id)).count == values.count
  }
}

public enum CodexResourceKind: String, Codable, CaseIterable, Sendable { case plugins, skills, apps }
public struct CodexComposerResource: Codable, Equatable, Sendable, Identifiable {
  public let attachment: CodexInputAttachment
  public let title: String
  public let detail: String
  public let enabled: Bool
  public var id: String { attachment.id }
  public init(attachment: CodexInputAttachment, title: String, detail: String, enabled: Bool) {
    self.attachment = attachment; self.title = title; self.detail = detail; self.enabled = enabled
  }
}
public struct CodexResourcePage: Codable, Equatable, Sendable {
  public let resources: [CodexComposerResource]
  public let nextCursor: String?
  public let notice: String?
  public init(resources: [CodexComposerResource], nextCursor: String? = nil, notice: String? = nil) {
    self.resources = resources; self.nextCursor = nextCursor; self.notice = notice
  }
}
