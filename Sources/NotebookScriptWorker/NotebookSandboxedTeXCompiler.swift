import Foundation
import NotebookScriptProtocol
import Darwin

/// Invoked only by the markup XPC service. The signed child inherits that
/// service's App Sandbox; neither process receives a user-data bookmark,
/// descriptor, path capability or network entitlement. TeX flags do not form
/// a filesystem sandbox and must never replace this process boundary.
enum NotebookSandboxedTeXCompiler {
  private static let children = NotebookCompilerChildren.shared

  static func compile(_ request: NotebookCompilerRequest) async -> NotebookWorkerReply {
    do {
      let value = try await compileSource(request)
      return .init(value: try JSONEncoder().encode(value))
    } catch let failure as Failure {
      return .init(code: failure.code, message: failure.message)
    } catch let failure as NotebookExportImageRenderer.Failure {
      return .init(code: "export_image_invalid", message: failure.message)
    } catch is CancellationError {
      return .init(code: "export_cancelled", message: "Компиляция остановлена.")
    } catch {
      return .init(code: "export_failed", message: String(describing: error))
    }
  }

  private struct Failure: Error { let code: String; let message: String }

  private static func compileSource(_ request: NotebookCompilerRequest) async throws -> NotebookCompilerResult {
    let source = request.source
    let deadline = ContinuousClock.now + .seconds(120)
    guard request.assets.count <= 128, Set(request.assets.map(\.name)).count == request.assets.count,
      request.assets.enumerated().allSatisfy({ index, asset in
        asset.name == "notebook-image-\(index).pdf" && !asset.data.isEmpty && asset.data.count <= 8*1024*1024
      }), request.assets.reduce(0, { $0 + $1.data.count }) <= 16*1024*1024 else {
      throw Failure(code: "resource_limit", message: "Встроенные изображения превышают 128 файлов, 8 МиБ на файл или 16 МиБ всего.")
    }
    guard source.utf8.count <= 4*1024*1024 else {
      throw Failure(code: "resource_limit", message: "Печатный исходник превышает 4 МиБ.")
    }
    let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/NotebookTeX", isDirectory: true)
    let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tectonic")
    let bundle = resources.appendingPathComponent("texlive.zip")
    guard FileManager.default.isExecutableFile(atPath: executable.path),
      FileManager.default.fileExists(atPath: bundle.path) else {
      throw Failure(code: "compiler_unavailable", message: "В сборке отсутствуют закреплённые ресурсы экспорта TeX.")
    }
    // A fresh cache builds formats from the pinned distribution. In particular
    // it cannot load private .fmt files from the Mac user's Tectonic cache.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("notebook-tex-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let tex = directory.appendingPathComponent("document.tex")
    try Data(source.utf8).write(to: tex, options: .atomic)
    // Asset rendering happens serially, before the child starts and entirely
    // outside the host's writer. No source image ever becomes a user-file URL.
    var prepared: [NotebookCompilerFile] = []
    for asset in request.assets {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else { throw Failure(code: "export_timeout", message: "Экспорт остановлен через 120 секунд.") }
      let data: Data
      if asset.mediaType == .svg { data = try await renderSVG(asset.data, directory: directory, deadline: deadline) }
      else { data = try NotebookExportImageRenderer.rasterPDF(asset.data) }
      guard data.count + prepared.reduce(0, { $0 + $1.data.count }) <= 8*1024*1024 else {
        throw Failure(code: "resource_limit", message: "Подготовленные изображения превышают 8 МиБ.")
      }
      try data.write(to: directory.appendingPathComponent(asset.name), options: .atomic)
      prepared.append(.init(name: asset.name, data: data))
    }

    let process = Process(), output = Pipe(), capture = Tail()
    process.executableURL = executable
    process.arguments = ["--untrusted", "--only-cached", "--bundle", bundle.path,
      "--keep-logs", "--synctex", "--outdir", directory.path, tex.path]
    process.environment = ["HOME": directory.path, "TMPDIR": directory.path,
      "TECTONIC_CACHE_DIR": directory.appendingPathComponent("cache").path,
      "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
    process.currentDirectoryURL = directory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output; process.standardError = output
    try Task.checkCancellation()
    let child: NotebookCompilerProcess
    do { child = try children.start(process) }
    catch { throw Failure(code: "compiler_unavailable", message: "Изолированный компилятор не запустился: \(error)") }
    defer { children.remove(process) }
    try? output.fileHandleForWriting.close()
    let outputReader = NotebookCompilerPipe(reading: output.fileHandleForReading, deadline: deadline) { capture.append($0) }
    do {
      while !child.hasExited {
        try Task.checkCancellation()
        if ContinuousClock.now >= deadline {
          throw Failure(code: "export_timeout", message: "Компиляция остановлена через 120 секунд.")
        }
        let memory = NotebookCompilerMemory.observe(process.processIdentifier)
        // An absent kernel task can precede Foundation's terminal callback.
        // Continue this bounded wait; only the child owner confirms its exit.
        if case .unavailable(let code, let count) = memory, !child.hasExited {
          throw Failure(code: "compiler_unavailable", message: "Не удалось проверить память изолированного компилятора (код \(code), ответ \(count)).")
        }
        if temporaryBytes(directory) > 128*1024*1024 || memory.exceeds(1024*1024*1024) {
          throw Failure(code: "resource_limit", message: "Компилятор превысил 128 МиБ временных файлов или 1 ГиБ памяти.")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
    } catch {
      child.terminate(); outputReader.cancel()
      _ = await child.waitForExit()
      _ = await outputReader.finish()
      throw error
    }
    let status = await child.waitForExit()
    if let failure = await outputReader.finish() {
      throw Failure(code: failure == .deadline ? "export_timeout" : "export_failed", message: "Не прочитан вывод компилятора: \(failure)")
    }
    guard status == 0 else {
      throw Failure(code: "export_failed", message: capture.text)
    }
    let pdf = directory.appendingPathComponent("document.pdf")
    let attributes = try FileManager.default.attributesOfItem(atPath: pdf.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? Int, size <= 16*1024*1024 else {
      throw Failure(code: "resource_limit", message: "PDF превышает 16 МиБ.")
    }
    let data = try Data(contentsOf: pdf)
    guard data.starts(with: Data("%PDF-".utf8)) else { throw Failure(code: "export_failed", message: "Нет готового PDF.") }
    guard data.count + prepared.reduce(0, { $0 + $1.data.count }) <= 17*1024*1024 else {
      throw Failure(code: "resource_limit", message: "PDF и изображения вместе превышают 17 МиБ.")
    }
    let mappingURL = directory.appendingPathComponent("document.synctex.gz")
    let mappingAttributes = try FileManager.default.attributesOfItem(atPath: mappingURL.path)
    guard mappingAttributes[.type] as? FileAttributeType == .typeRegular,
      let mappingSize = mappingAttributes[.size] as? Int, (1...4*1024*1024).contains(mappingSize) else {
      throw Failure(code: "resource_limit", message: "Карта печатных страниц отсутствует или превышает 4 МиБ.")
    }
    let syncTeX = try Data(contentsOf: mappingURL)
    guard syncTeX.starts(with: [0x1f, 0x8b]) else {
      throw Failure(code: "export_failed", message: "Нет допустимой карты печатных страниц.")
    }
    return .init(pdf: data, log: capture.text, assets: prepared, syncTeX: syncTeX)
  }

  private static func renderSVG(_ input: Data, directory: URL, deadline: ContinuousClock.Instant) async throws -> Data {
    let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/notebook-image-compiler")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw Failure(code: "compiler_unavailable", message: "В сборке отсутствует закреплённый SVG-компилятор.")
    }
    let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    let pixels = BoundedOutput(maximum: 8*1024*1024), diagnostic = Tail()
    process.executableURL = executable; process.arguments = []
    process.environment = ["HOME": directory.path, "TMPDIR": directory.path, "LANG": "en_US.UTF-8"]
    process.currentDirectoryURL = directory
    process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
    let imageDeadline = min(deadline, .now + .seconds(10))
    let child = try children.start(process); defer { children.remove(process) }
    try? stdin.fileHandleForReading.close()
    try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
    let outputReader = NotebookCompilerPipe(reading: stdout.fileHandleForReading, deadline: imageDeadline) { pixels.append($0) }
    let errorReader = NotebookCompilerPipe(reading: stderr.fileHandleForReading, deadline: imageDeadline) { diagnostic.append($0) }
    let inputWriter = NotebookCompilerPipe(writing: stdin.fileHandleForWriting, data: input, deadline: imageDeadline)
    do {
      while !child.hasExited {
        try Task.checkCancellation()
        if .now >= imageDeadline { throw Failure(code: "export_timeout", message: "SVG не подготовлен за 10 секунд.") }
        let memory = NotebookCompilerMemory.observe(process.processIdentifier)
        if case .unavailable(let code, let count) = memory, !child.hasExited {
          throw Failure(code: "compiler_unavailable", message: "Не удалось проверить память SVG-компилятора (код \(code), ответ \(count)).")
        }
        if pixels.exceeded || memory.exceeds(512*1024*1024) {
          throw Failure(code: "resource_limit", message: "SVG-компилятор превысил 8 МиБ вывода или 512 МиБ памяти.")
        }
        try await Task.sleep(for: .milliseconds(20))
      }
    } catch {
      child.terminate(); inputWriter.cancel(); outputReader.cancel(); errorReader.cancel()
      _ = await child.waitForExit()
      _ = await inputWriter.finish()
      _ = await outputReader.finish(); _ = await errorReader.finish()
      throw error
    }
    let status = await child.waitForExit()
    let inputFailure = await inputWriter.finish()
    let outputFailure = await outputReader.finish(), errorFailure = await errorReader.finish()
    if let failure = outputFailure ?? errorFailure ?? inputFailure, failure == .deadline {
      throw Failure(code: "export_timeout", message: "SVG не подготовлен за 10 секунд.")
    }
    guard status == 0 else { throw Failure(code: "export_image_invalid", message: diagnostic.text) }
    if let failure = outputFailure ?? errorFailure ?? inputFailure {
      throw Failure(code: "export_image_invalid", message: "Не завершён обмен с SVG-компилятором: \(failure)")
    }
    let result = pixels.data
    guard !pixels.exceeded, result.starts(with: Data("%PDF-".utf8)) else {
      throw Failure(code: "export_image_invalid", message: "SVG-компилятор не вернул допустимый PDF.")
    }
    return result
  }

  private final class BoundedOutput: @unchecked Sendable {
    let maximum: Int; private let lock = NSLock(); private var bytes = Data(); private var overflow = false
    init(maximum: Int) { self.maximum = maximum }
    func append(_ value: Data) { lock.withLock {
      if value.count > maximum - bytes.count { overflow = true }
      bytes.append(value.prefix(maximum - bytes.count))
    } }
    var data: Data { lock.withLock { bytes } }
    var exceeded: Bool { lock.withLock { overflow } }
  }

  private static func temporaryBytes(_ directory: URL) -> Int {
    guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
    var bytes = 0, count = 0
    for case let file as URL in files {
      count += 1
      if count > 2048 { return Int.max }
      if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
        bytes += values.fileSize ?? 0
      }
      if bytes > 128*1024*1024 { return bytes }
    }
    return bytes
  }

  private final class Tail: @unchecked Sendable {
    let lock = NSLock()
    var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data); if bytes.count > 8000 { bytes = bytes.suffix(8000) } } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
  }

}
