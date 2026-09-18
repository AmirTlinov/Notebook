import Foundation
import CryptoKit

/// Identity comes from this signed application, never from MCP or a user path.
/// Missing compiler assets do not prevent attaching to an already saved run.
enum NotebookTypeScriptPreparation {
  struct Identity: Decodable, Sendable {
    let format: Int
    let compilerVersion: String
    let sdkVersion: String
  }
  static let bundledIdentity: Identity? = {
    let contents = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/NotebookMarkupService.xpc/Contents")
    guard FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("Helpers/notebook-typescript").path),
      let bytes = try? Data(contentsOf: contents.appendingPathComponent("Resources/NotebookTypeScript/manifest.json")), bytes.count <= 16_384,
      let identity = try? JSONDecoder().decode(Identity.self, from: bytes), identity.format == 2, !identity.compilerVersion.isEmpty,
      let sdk = Bundle.module.url(forResource: "notebook-sdk", withExtension: "d.ts"),
      let declarations = try? Data(contentsOf: sdk),
      identity.sdkVersion == SHA256.hash(data: declarations).map({ String(format: "%02x", $0) }).joined() else { return nil }
    return identity
  }()
}
