import Foundation
import CryptoKit
import Testing
import NotebookScriptProtocol
@testable import NotebookScriptWorker

@Suite(.serialized)
struct NotebookTypeScriptCompilerTests {
  private func prepared() throws -> (URL, String) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let stages = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".build/notebook-typescript-runtime"), includingPropertiesForKeys: nil)
    let sdk = try Data(contentsOf: root.appendingPathComponent("Sources/NotebookScriptHost/Resources/notebook-sdk.d.ts"))
    let lock = try Data(contentsOf: root.appendingPathComponent("Sources/NotebookMarkupService/TypeScriptResources.lock.json"))
    let lockHash = SHA256.hash(data: lock).map { String(format: "%02x", $0) }.joined()
    for stage in stages {
      if (try? Data(contentsOf: stage.appendingPathComponent("Resources/NotebookTypeScript/notebook-sdk.d.ts"))) == sdk {
        let manifest = try JSONDecoder().decode(NotebookSandboxedTypeScriptCompiler.Manifest.self,
          from: Data(contentsOf: stage.appendingPathComponent("Resources/NotebookTypeScript/manifest.json")))
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: stage.appendingPathComponent("Resources/NotebookTypeScript/manifest.json"))) as? [String: Any]
        guard manifest.format == 2, metadata?["sourceLockSHA256"] as? String == lockHash else { continue }
        return (stage, manifest.sdkVersion)
      }
    }
    throw CocoaError(.fileNoSuchFile)
  }
  @Test func actualPinnedCLITypechecksAndItsMapNamesOriginalSourceLines() async throws {
    let (stage,sdk) = try prepared()
    let source = "const n: number = 2;\nthrow new Error('source line two');"
    let result = try await NotebookSandboxedTypeScriptCompiler.compileSource(.init(id: UUID(), source: source, compilerVersion: "7.0.2", sdkVersion: sdk), contents: stage)
    let engine = NotebookQuickJSEngine(bootstrap: "") { _,_,done in done(.init(code: "unexpected_effect")) }
    let reply: NotebookWorkerReply = await withCheckedContinuation { continuation in
      engine.start(code: result.javaScript, arguments: Data("null".utf8)) { continuation.resume(returning: $0) }
    }
    let map = try NotebookTypeScriptSourceMap(data: result.sourceMap)
    #expect(map.map(reply.message ?? "").contains("notebook-user.ts:2:"))
    #expect(result.peakResidentBytes > 0 && result.wallMilliseconds > 0)
  }
  @Test(arguments: ["const n: number = 'bad'; await emit(n);", "const path: string = '/private/canary'; await import(path);", "const fs = require('/private/canary');", "const = ;", "const value ="])
  func errorsAndImportsNeverProduceJavaScript(_ source: String) async throws {
    let (stage,sdk) = try prepared()
    do {
      _ = try await NotebookSandboxedTypeScriptCompiler.compileSource(.init(id: UUID(), source: source, compilerVersion: "7.0.2", sdkVersion: sdk), contents: stage)
      Issue.record("Invalid TypeScript cannot reach the user worker")
    } catch let failure as NotebookSandboxedTypeScriptCompiler.Failure {
      #expect(failure.code == "typescript_diagnostic")
      #expect(failure.message.contains("notebook-user.ts(1,"))
    }
  }
  @Test func cancelledPreparationAndChangedPinsCannotCompile() async throws {
    let (stage,sdk) = try prepared()
    let request = NotebookTypeScriptRequest(id: UUID(), source: "return 1;", compilerVersion: "7.0.2", sdkVersion: sdk)
    let job = Task { try await NotebookSandboxedTypeScriptCompiler.compileSource(request, contents: stage) }
    job.cancel()
    await #expect(throws: CancellationError.self) { _ = try await job.value }
    await #expect(throws: NotebookSandboxedTypeScriptCompiler.Failure.self) {
      _ = try await NotebookSandboxedTypeScriptCompiler.compileSource(.init(id: UUID(), source: request.source, compilerVersion: "different", sdkVersion: sdk), contents: stage)
    }
  }
  @Test func cancellingAnActuallyLaunchedCLIWaitsForChildCleanup() async throws {
    let (stage,sdk) = try prepared()
    let source = "const values: number[] = [" + String(repeating: "1234,", count: 45_000) + "]; return values.length;"
    let job = Task { try await NotebookSandboxedTypeScriptCompiler.compileSource(
      .init(id: UUID(), source: source, compilerVersion: "7.0.2", sdkVersion: sdk), contents: stage) }
    let deadline = ContinuousClock.now + .seconds(5)
    while NotebookCompilerChildren.shared.activeProcessIDs.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    let children = NotebookCompilerChildren.shared.activeProcessIDs
    #expect(!children.isEmpty)
    job.cancel()
    await #expect(throws: CancellationError.self) { _ = try await job.value }
    #expect(NotebookCompilerChildren.shared.activeProcessIDs.isEmpty)
    for pid in children { #expect(NotebookCompilerMemory.observe(pid) == .taskAbsent) }
  }

  @Test func everyProductionResourceFenceRejectsAndCleansUpARealCLI() async throws {
    let (stage,sdk) = try prepared()
    let load = "const values: number[] = [" + String(repeating: "1234,", count: 45_000) + "]; return values.length;"
    typealias Limits = NotebookSandboxedTypeScriptCompiler.Limits
    let cases: [(String, String, Limits, String)] = [
      ("CPU", load, .init(cpuNanoseconds: 0), "resource_limit"),
      ("RSS", load, .init(residentBytes: 1), "resource_limit"),
      ("temporary files", load, .init(temporaryBytes: 1), "resource_limit"),
      ("wall", load, .init(wall: .milliseconds(1)), "typescript_timeout"),
      ("diagnostics", "const n: number = 'wrong';", .init(diagnosticBytes: 16), "resource_limit"),
      ("JavaScript", "enum E {a,b,c,d,e,f,g,h,i,j,k}; return E.k;", .init(javaScriptBytes: 128), "resource_limit"),
      ("source map", "return 1;", .init(mapBytes: 1), "resource_limit"),
    ]
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    func workingDirectories() throws -> Set<String> {
      Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("notebook-typescript-") })
    }
    for (name,source,limits,expected) in cases {
      let before = try workingDirectories()
      do {
        _ = try await NotebookSandboxedTypeScriptCompiler.compileSource(
          .init(id: UUID(), source: source, compilerVersion: "7.0.2", sdkVersion: sdk), contents: stage, limits: limits)
        Issue.record("The real compiler escaped its \(name) fence")
      } catch let failure as NotebookSandboxedTypeScriptCompiler.Failure {
        #expect(failure.code == expected, "\(name): \(failure.message)")
      }
      #expect(NotebookCompilerChildren.shared.activeProcessIDs.isEmpty, "\(name) leaked a child")
      #expect(try workingDirectories() == before, "\(name) leaked a working directory")
    }
  }

  @Test func tripleSlashPathsCannotExtendTheExplicitDeclarationSet() async throws {
    let (stage,sdk) = try prepared()
    let canary = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-ts-private-\(UUID()).d.ts")
    try Data("declare const privateTypeCanary: 42;".utf8).write(to: canary)
    defer { try? FileManager.default.removeItem(at: canary) }
    let source = "/// <reference path=\"\(canary.path)\" />\nreturn privateTypeCanary;"
    do {
      _ = try await NotebookSandboxedTypeScriptCompiler.compileSource(
        .init(id: UUID(), source: source, compilerVersion: "7.0.2", sdkVersion: sdk), contents: stage)
      Issue.record("User paths extended the owned compiler input set")
    } catch let failure as NotebookSandboxedTypeScriptCompiler.Failure {
      #expect(failure.code == "typescript_diagnostic")
      #expect(failure.message.contains("notebook-user.ts(2,"))
    }
  }

}
