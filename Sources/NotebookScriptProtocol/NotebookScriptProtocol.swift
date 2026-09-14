import Foundation

public enum NotebookScriptServiceNames {
  public static let user = "com.amirtlinov.notebook.script-service"
  public static let markup = "com.amirtlinov.notebook.markup-service"
}

/// Data-only XPC messages. The worker receives no URL, descriptor, bookmark,
/// SQLite handle, Core object or inherited data-container entitlement.
@objc public protocol NotebookScriptServiceProtocol {
  func execute(_ request: Data, withReply reply: @escaping (Data) -> Void)
  /// Only the trusted markup service accepts this data-only compilation RPC.
  func compile(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func cancel(_ runID: String, withReply reply: @escaping () -> Void)
}

@objc public protocol NotebookScriptBrokerProtocol {
  func call(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public struct NotebookWorkerRequest: Codable, Sendable {
  public let id: UUID
  public let code: String
  public let arguments: Data
  public init(id: UUID, code: String, arguments: Data) { self.id = id; self.code = code; self.arguments = arguments }
}

public struct NotebookWorkerCall: Codable, Sendable {
  public let runID: UUID
  public let sequence: UInt64
  public let method: String
  public let arguments: Data
  public init(runID: UUID, sequence: UInt64, method: String, arguments: Data) {
    self.runID = runID; self.sequence = sequence; self.method = method; self.arguments = arguments
  }
}

public struct NotebookWorkerReply: Codable, Sendable {
  public let value: Data?
  public let code: String?
  public let message: String?
  public init(value: Data? = nil, code: String? = nil, message: String? = nil) {
    self.value = value; self.code = code; self.message = message
  }
}

public struct NotebookCompilerRequest: Codable, Sendable {
  public let id: UUID
  public let source: String
  public let assets: [NotebookCompilerAsset]
  public init(id: UUID, source: String, assets: [NotebookCompilerAsset] = []) {
    self.id = id; self.source = source; self.assets = assets
  }
}

/// An embedded image is a bounded value, not an arbitrary filesystem capability.
public struct NotebookCompilerAsset: Codable, Sendable {
  public enum MediaType: String, Codable, Sendable { case svg = "image/svg+xml", png = "image/png", jpeg = "image/jpeg" }
  public let name: String
  public let mediaType: MediaType
  public let data: Data
  public init(name: String, mediaType: MediaType, data: Data) { self.name = name; self.mediaType = mediaType; self.data = data }
}
public struct NotebookCompilerFile: Codable, Sendable {
  public let name: String
  public let data: Data
  public init(name: String, data: Data) { self.name = name; self.data = data }
}
public struct NotebookCompilerResult: Codable, Sendable {
  public let pdf: Data
  public let log: String
  public let assets: [NotebookCompilerFile]
  public init(pdf: Data, log: String, assets: [NotebookCompilerFile] = []) { self.pdf = pdf; self.log = log; self.assets = assets }
}
