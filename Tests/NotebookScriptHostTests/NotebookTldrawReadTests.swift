import Foundation
import Testing
@testable import NotebookCore
@testable import NotebookScriptHost

@MainActor @Suite("tldraw SDK preparation",.serialized)
struct NotebookTldrawReadTests {
  @Test func sameConverterWithoutWritingOrGrantingDestinationAuthority() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("tldraw-sdk-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let owner=NotebookSDKV2ReadTests.Owner.self
    let session=try owner.init()
    defer { try? FileManager.default.removeItem(at:session.store.root) }
    let host=NotebookScriptCoordinator(command:{ try await session.read($0) },persistence:{ try await session.persist($0) },workingDirectory:root)
    let source=#"{"schema":{"schemaVersion":2,"sequences":{}},"shapes":[{"id":"shape:a","type":"geo","parentId":"page:a","index":"a1","x":10,"y":20,"rotation":0,"props":{"geo":"triangle","w":120,"h":100}}],"bindings":[]}"#
    let namespace=UUID(), before=try session.store.currentReadCursor()
    let snapshot=try await host.context(.init(method:"prepareTldraw",arguments:.object(["source":.string(source),"namespace":.string(namespace.uuidString)])))
    let expected=try NotebookTldrawImport.prepare(source:source,namespace:namespace)
    #expect(snapshot["data"] == (try .encode(expected)))
    #expect(snapshot["basis"]?["owners"] == .array([]))
    #expect(snapshot["data"]?["canInsert"] == .bool(true))
    #expect(try session.store.currentReadCursor() == before)
    #expect(NotebookScriptAPI.readMethods.contains("prepareTldraw"))
    #expect(try NotebookScriptAPI.documentation("prepareTldraw")["contract"] != nil)
  }
}
