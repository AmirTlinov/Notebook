import Foundation
import NotebookScriptProtocol

/// Only the signed markup service calls this compiler. Its child inherits the
/// existing sandbox; the user interpreter still receives JavaScript and data.
enum NotebookSandboxedTypeScriptCompiler {
  static let maximumSourceBytes = 262_144, maximumJavaScriptBytes = 262_144
  static let maximumMapBytes = 1_048_576, maximumDiagnosticBytes = 65_536
  static let maximumTemporaryBytes = 4_194_304
  static let maximumResidentBytes: UInt64 = 512*1024*1024
  static let maximumCPUNanoseconds: UInt64 = 5_000_000_000
  static let wallSeconds = 10

  /// Test-only narrowing uses the same real CLI and cleanup path. The data-only
  /// RPC has no limit/configuration fields and always uses these production defaults.
  struct Limits: Sendable {
    var javaScriptBytes = maximumJavaScriptBytes
    var mapBytes = maximumMapBytes
    var diagnosticBytes = maximumDiagnosticBytes
    var temporaryBytes = maximumTemporaryBytes
    var residentBytes = maximumResidentBytes
    var cpuNanoseconds = maximumCPUNanoseconds
    var wall: Duration = .seconds(wallSeconds)
  }

  struct Manifest: Decodable {
    let format: Int; let compilerVersion: String; let sdkVersion: String; let libraries: [String]
  }
  struct Failure: Error { let code: String; let message: String }

  static func compile(_ request: NotebookTypeScriptRequest) async -> NotebookWorkerReply {
    do {
      let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
      let result = try await compileSource(request, contents: contents)
      return .init(value: try JSONEncoder().encode(result))
    } catch let error as Failure { return .init(code: error.code, message: error.message) }
    catch is CancellationError { return .init(code: "run_cancelled", message: "Подготовка TypeScript отменена.") }
    catch { return .init(code: "typescript_failed", message: String(describing: error)) }
  }

  /// Internal injection is used only by compiler tests. The RPC has no paths.
  static func compileSource(_ request: NotebookTypeScriptRequest, contents: URL, limits: Limits = .init()) async throws -> NotebookTypeScriptResult {
    guard request.source.utf8.count <= maximumSourceBytes else { throw Failure(code: "resource_limit", message: "Исходник TypeScript превышает 256 КиБ.") }
    let resources = contents.appendingPathComponent("Resources/NotebookTypeScript"), executable = contents.appendingPathComponent("Helpers/notebook-typescript")
    guard FileManager.default.isExecutableFile(atPath: executable.path),
      let bytes = try? Data(contentsOf: resources.appendingPathComponent("manifest.json")),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes), manifest.format == 2,
      !manifest.libraries.isEmpty, manifest.libraries.allSatisfy({ $0.hasPrefix("lib.es") || $0.hasPrefix("lib.decorators") }),
      manifest.libraries.allSatisfy({ !$0.contains("/") && $0.hasSuffix(".d.ts") }) else {
      throw Failure(code: "compiler_unavailable", message: "Нет закреплённого CLI TypeScript и стандартных деклараций.")
    }
    guard manifest.compilerVersion == request.compilerVersion, manifest.sdkVersion == request.sdkVersion else {
      throw Failure(code: "compiler_identity_mismatch", message: "Подготовка не меняет компилятор или SDK уже допущенного run.")
    }
    try Task.checkCancellation()
    let started = ContinuousClock.now, deadline = started + limits.wall
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("notebook-typescript-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    // An async body, not a user-controlled module or project. noResolve and
    // explicit noLib files prevent imports/references from extending the set.
    let source = "async function __notebook_program__() {\n" + request.source + "\n}\n"
    try Data(source.utf8).write(to: directory.appendingPathComponent("program.ts"), options: .atomic)
    let files = manifest.libraries.map { resources.appendingPathComponent($0).path }
      + [resources.appendingPathComponent("notebook-sdk.d.ts").path, directory.appendingPathComponent("program.ts").path]
    let options: [String: Any] = ["target": "es2022", "module": "es2015", "moduleDetection": "legacy", "strict": true,
      "noEmitOnError": true, "noCheck": false, "noResolve": true, "noLib": true, "types": [String](),
      "sourceMap": true, "removeComments": true, "rootDir": directory.path, "outDir": directory.appendingPathComponent("out").path]
    let configuration = try JSONSerialization.data(withJSONObject: ["compilerOptions": options, "files": files], options: [.sortedKeys])
    try configuration.write(to: directory.appendingPathComponent("tsconfig.json"), options: .atomic)
    let process = Process(), output = Pipe(), capture = DiagnosticBuffer(maximum: limits.diagnosticBytes)
    process.executableURL = executable; process.arguments = ["--project", "tsconfig.json", "--pretty", "false"]
    process.currentDirectoryURL = directory
    process.environment = ["HOME": directory.path, "TMPDIR": directory.path, "LANG": "en_US.UTF-8",
      "GOMAXPROCS": "2", "GOMEMLIMIT": "384MiB"]
    process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
    try Task.checkCancellation()
    let child = try NotebookCompilerChildren.shared.start(process)
    defer { NotebookCompilerChildren.shared.remove(process) }
    try? output.fileHandleForWriting.close()
    let reader = NotebookCompilerPipe(reading: output.fileHandleForReading, deadline: deadline) { capture.append($0) }
    var peak: UInt64 = 0, cpu: UInt64 = 0
    do {
      while !child.hasExited {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw Failure(code: "typescript_timeout", message: "TypeScript превысил 10 секунд подготовки.") }
        let usage = NotebookCompilerMemory.measure(process.processIdentifier)
        if case .unavailable = usage.memory, !child.hasExited {
          throw Failure(code: "compiler_unavailable", message: "Ресурсные пределы TypeScript нельзя подтвердить.")
        }
        if case .resident(let resident) = usage.memory { peak = max(peak, resident) }
        cpu = max(cpu, usage.cpuNanoseconds ?? 0)
        guard peak <= limits.residentBytes, cpu <= limits.cpuNanoseconds,
          !capture.exceeded, try temporaryBytes(directory) <= limits.temporaryBytes else {
          throw Failure(code: "resource_limit", message: "TypeScript превысил 5 CPU секунд, 512 МиБ памяти, 4 МиБ временных файлов или 64 КиБ диагностики.")
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      try Task.checkCancellation()
    } catch {
      child.terminate(); reader.cancel(); _ = await child.waitForExit(); _ = await reader.finish(); throw error
    }
    let status = await child.waitForExit(), readingFailure = await reader.finish()
    try Task.checkCancellation()
    guard readingFailure == nil, !capture.exceeded else { throw Failure(code: "resource_limit", message: "Не получена ограниченная диагностика TypeScript.") }
    guard status == 0 else {
      throw Failure(code: capture.text.contains("error TS") ? "typescript_diagnostic" : "typescript_failed",
        message: diagnostic(capture.text, directory: directory, source: request.source))
    }
    let outputDirectory = directory.appendingPathComponent("out")
    let javaScript = try boundedFile(outputDirectory.appendingPathComponent("program.js"), maximum: limits.javaScriptBytes - 64)
    let map = try boundedFile(outputDirectory.appendingPathComponent("program.js.map"), maximum: limits.mapBytes)
    guard let program = String(data: javaScript, encoding: .utf8) else { throw Failure(code: "typescript_failed", message: "Компилятор не вернул JavaScript.") }
    let prepared = program.replacingOccurrences(of: "//# sourceMappingURL=program.js.map", with: "") + "\nreturn await __notebook_program__();"
    let duration = started.duration(to: .now).components
    return .init(javaScript: prepared, sourceMap: map, compilerVersion: manifest.compilerVersion, sdkVersion: manifest.sdkVersion,
      wallMilliseconds: Double(duration.seconds)*1000 + Double(duration.attoseconds)/1e15, peakResidentBytes: peak, cpuNanoseconds: cpu)
  }

  static func diagnostic(_ value: String, directory: URL, source: String) -> String {
    // CLI locations refer to one owned wrapper line. Keep type codes and
    // columns, but never expose temporary paths as the user's source address.
    let expression = try! NSRegularExpression(pattern: #"(?:[^\n]*[/\\])?program\.ts\((\d+),(\d+)\)"#)
    var result = value
    let sourceLines = source.components(separatedBy: "\n")
    for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
      guard let range = Range(match.range, in: result), let lineRange = Range(match.range(at: 1), in: value),
        let columnRange = Range(match.range(at: 2), in: value), let line = Int(value[lineRange]) else { continue }
      let originalLine = max(1, min(sourceLines.count, line - 1))
      let column = line - 1 > sourceLines.count ? String((sourceLines.last?.utf16.count ?? 0) + 1) : String(value[columnRange])
      result.replaceSubrange(range, with: "notebook-user.ts(\(originalLine),\(column))")
    }
    return String(result.replacingOccurrences(of: directory.path, with: "<compiler>").prefix(4096))
  }

  private static func boundedFile(_ url: URL, maximum: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= maximum else {
      throw Failure(code: "resource_limit", message: "Скомпилированный код или source map превышает предел.")
    }
    return try Data(contentsOf: url)
  }
  private static func temporaryBytes(_ directory: URL) throws -> Int {
    guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { throw Failure(code: "compiler_unavailable", message: "Не проверен временный каталог.") }
    var count = 0, total = 0
    for case let url as URL in files {
      count += 1; if count > 16 { return Int.max }
      total += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      if total > maximumTemporaryBytes { break }
    }
    return total
  }
  private final class DiagnosticBuffer: @unchecked Sendable {
    let maximum: Int
    private let lock = NSLock(); private var bytes = Data(); private var overflow = false
    init(maximum: Int) { self.maximum = maximum }
    func append(_ value: Data) { lock.withLock {
      let left = maximum - bytes.count
      if value.count > left { overflow = true }; bytes.append(value.prefix(left))
    } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    var exceeded: Bool { lock.withLock { overflow } }
  }
}
