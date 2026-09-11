import Foundation
import NotebookCore

/// A single desktop frame has the desktop protocol's 256 MiB wire bound, not a
/// 256 MiB Swift-value budget. Large frames go to a private temporary file; the
/// decoder maps it and retains only the bounded display/control projection.
final class CodexDesktopFrames {
  static let wireLimit = 256 * 1_048_576
  private(set) var partialSince: ContinuousClock.Instant?
  private var header = Data()
  private var size: Int?
  private var received = 0
  private var memory = Data()
  private var file: FileHandle?
  private(set) var temporaryURL: URL?
  deinit { reset() }

  func append(_ input: Data) throws -> [JSONValue] {
    var offset = 0, result: [JSONValue] = []
    while offset < input.count {
      if partialSince == nil { partialSince = .now }
      if size == nil {
        let headerBytes = min(4 - header.count, input.count - offset)
        header.append(input.subdata(in: (input.startIndex + offset)..<(input.startIndex + offset + headerBytes))); offset += headerBytes
        if header.count < 4 { continue }
        let count = header.enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        guard count > 0, count <= Self.wireLimit else { throw CodexBridgeError.invalidFrame }
        size = count
        if count > 1_048_576 {
          let url = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-codex-frame-" + UUID().uuidString)
          guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CodexBridgeError.unavailable }
          temporaryURL = url; file = try FileHandle(forUpdating: url)
        }
      }
      let count = min(size! - received, input.count - offset)
      if count > 0 {
        let bytes = input.subdata(in: (input.startIndex + offset)..<(input.startIndex + offset + count))
        if let file { try file.write(contentsOf: bytes) } else { memory.append(bytes) }
        received += count; offset += count
      }
      if received == size {
        let data: Data
        if let file, let url = temporaryURL {
          try file.close(); self.file = nil
          data = try Data(contentsOf: url, options: .alwaysMapped)
        } else { data = memory }
        let decoder = JSONDecoder()
        decoder.userInfo[CodexWireProjection.largeFrameKey] = data.count > CodexDesktopProtocol.frameLimit
        let projected = try decoder.decode(CodexWireProjection.self, from: data).value
        guard try JSONEncoder().encode(projected).count <= CodexDesktopProtocol.frameLimit else { throw CodexBridgeError.historyLimit }
        result.append(projected); reset()
      }
    }
    return result
  }
  func checkDeadline(now: ContinuousClock.Instant = .now) throws {
    if let partialSince, now > partialSince.advanced(by: .seconds(10)) { throw CodexBridgeError.timeout }
  }
  private func reset() {
    try? file?.close(); file = nil
    if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    temporaryURL = nil; size = nil; received = 0; header = Data(); memory = Data(); partialSince = nil
  }
}
