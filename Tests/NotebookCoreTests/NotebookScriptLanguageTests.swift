import Foundation
import Testing
@testable import NotebookCore

struct NotebookScriptLanguageTests {
  @Test func aDeclaredLanguageIsNeverSilentlyAdmittedAsJavaScript() throws {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-language-\(UUID())"))
    defer { try? FileManager.default.removeItem(at: store.root) }
    _ = try store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    for language in ["typescript", "python"] {
      let raw: JSONValue = .object(["op": .string("start"), "runID": try .encode(UUID()), "apiVersion": .number(2),
        "language": .string(language), "code": .string("const n: number = 2; return n;")])
      #expect(throws: (any Error).self) {
        // TypeScript requires a compiler identity selected by the native host;
        // an unknown language is not a request for JavaScript.
        let request = try raw.decode(NotebookScriptRequest.self)
        _ = try store.admitScriptRun(request)
      }
    }
  }
}

extension NotebookScriptLanguageTests {
  @Test func compilerAndSDKPinsBelongToFirstAdmissionNotToRetryIdentity() throws {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-ts-identity-\(UUID())"))
    defer { try? FileManager.default.removeItem(at: store.root) }
    _ = try store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    var request = NotebookScriptRequest(op: .start, runID: UUID(), code: "const n: number = 2; return n;", language: .typescript)
    let first = try store.admitScriptRun(request, compilerVersion: "7.0.2", sdkVersion: String(repeating: "a", count: 64))
    #expect(first.language == .typescript && first.compilerVersion == "7.0.2")
    #expect(try store.admitScriptRun(request, compilerVersion: "future", sdkVersion: String(repeating: "b", count: 64)) == first)
    #expect(try store.admitScriptRun(request) == first, "Attach does not require the old compiler to still be installed")
    request.language = .javascript
    #expect(throws: CollaborationError.self) { _ = try store.admitScriptRun(request) }
    request.language = .typescript; request.code! += " "
    #expect(throws: CollaborationError.self) { _ = try store.admitScriptRun(request) }
  }
}
