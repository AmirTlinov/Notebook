import SwiftUI
import PDFKit
import JavaScriptCore

private struct ProbeResult: Sendable {
  let message: String
  let pdfURL: URL
  let pages: Int
  let text: String
  let elapsed: Double
  let memory: UInt64
  let width: Double
  let height: Double
  let linkCount: Int
}

private enum Compiler {
  static func memory() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { ptr in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
  }
  static func tex(_ markdown: String, paper: String = "a4", extra: String = "") throws -> String {
    return try autoreleasepool { try prepare(markdown, paper: paper, extra: extra) }
  }
  static func prepare(_ markdown: String, paper: String, extra: String) throws -> String {
    let context = JSContext()!
    let script = try String(contentsOf: Bundle.main.url(forResource: "notebook-markup", withExtension: "js")!, encoding: .utf8)
    context.evaluateScript(script)
    let value: [String: Any] = ["kind": "documentTeX", "document": ["paperSize": paper, "preamble": extra,
      "blocks": [["id": "body", "kind": "markdown", "source": markdown]]]]
    guard let result = context.objectForKeyedSubscript("notebookMarkup")?.call(withArguments: [value]),
      context.exception == nil, let source = result.objectForKeyedSubscript("source")?.toString() else {
      throw NSError(domain: "markup", code: 1, userInfo: [NSLocalizedDescriptionKey: context.exception?.toString() ?? "no source"])
    }
    return source
  }
  static func run(_ source: String, name: String, timeout: UInt64 = 120_000) -> ProbeResult {
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let cache = folder.appendingPathComponent("formats", isDirectory: true)
    try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let output = folder.appendingPathComponent(name + ".pdf")
    let bundle = Bundle.main.url(forResource: "texlive", withExtension: "zip")!
    let start = ContinuousClock.now
    let message = bundle.path.withCString { b in cache.path.withCString { c in source.withCString { s in output.path.withCString { o in
      let result = notebook_typeset_compile(b, c, s, o, timeout)!
      defer { notebook_typeset_free(result) }
      return String(cString: result)
    } } } }
    let (pages, text, width, height, links) = autoreleasepool { () -> (Int, String, Double, Double, Int) in
      let pdf = message.hasPrefix("OK") ? PDFDocument(url: output) : nil
      let rect = pdf?.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
      let count = (0..<(pdf?.pageCount ?? 0)).reduce(0) { total, index in
        total + (pdf?.page(at: index)?.annotations.filter { ($0.action as? PDFActionURL)?.url?.absoluteString == "https://example.com" }.count ?? 0)
      }
      return (pdf?.pageCount ?? 0, pdf?.string ?? "", rect.width, rect.height, count)
    }
    let duration = start.duration(to: .now).components
    let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    let result = ProbeResult(message: message, pdfURL: output, pages: pages,
      text: text, elapsed: elapsed, memory: memory(), width: width, height: height, linkCount: links)
    print("TYPESET_PROBE \(name) \(message) pages=\(result.pages) seconds=\(elapsed) footprint=\(result.memory)")
    fflush(stdout)
    return result
  }
}

@MainActor @Observable private final class Model {
  var source = "# Один печатный макет\n\nРусский текст на настоящем листе A4. Правка на iPad без Mac.\n\nФормула: $E = mc^2$.\n\n| Содержание | Значение |\n| --- | --- |\n| Бумага | A4 |\n| Текст | 12 pt |"
  var status = "Готов к автономной вёрстке"
  var url: URL?
  var busy = false
  var rows: [String] = []
  func render() {
    guard !busy else { return }
    busy = true; status = "Вёрстка…"
    let source = source
    Task {
      let result = await Task.detached { () -> ProbeResult in
        do { return Compiler.run(try Compiler.tex(source), name: "manual-\(UUID().uuidString)") }
        catch { return .init(message: String(describing: error), pdfURL: URL(filePath: "/invalid"), pages: 0, text: "", elapsed: 0, memory: 0, width: 0, height: 0, linkCount: 0) }
      }.value
      busy = false; status = "\(result.pages) стр. · \(String(format: "%.3f", result.elapsed)) с · \(result.memory / 1024 / 1024) МиБ\n\(result.message.prefix(150))"
      if result.pages > 0 { url = result.pdfURL }
    }
  }
  func acceptance() {
    guard !busy else { return }; busy = true
    Task {
      let output = await Task.detached { () -> ([String], URL?) in
        var rows: [String] = [], url: URL?
        func check(_ name: String, _ result: ProbeResult, _ expected: Bool) {
          let line = "\(expected ? "PASS" : "FAIL") \(name): \(String(format: "%.3f", result.elapsed))s \(result.pages)p \(result.memory/1024/1024)MiB · \(result.message.prefix(120))"
          rows.append(line); print("TYPESET_ACCEPTANCE " + line); fflush(stdout)
          if result.pages > 0 { url = result.pdfURL }
        }
        do {
          let text = "# Автономная вёрстка\n\nРусский текст. Formula $E=mc^2$.\n\n" + Array(repeating: "Настоящее соотношение текста и листа. Один макет для экрана и печати. ", count: 60).joined()
          for paper in ["a4", "letter"] {
            let result = Compiler.run(try Compiler.tex(text, paper: paper), name: "initial-\(paper)")
            check("paper-\(paper)", result, result.pages > 0 && result.text.contains("Автономная") && abs(result.width - (paper == "a4" ? 595.2756 : 612)) < 0.02 && abs(result.height - (paper == "a4" ? 841.8898 : 792)) < 0.02)
          }
          let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          let secret = folder.appendingPathComponent("private-test.tex")
          try "SECRET_MUST_NOT_LEAK".write(to: secret, atomically: true, encoding: .utf8)
          let attack = "\\documentclass{article}\\begin{document}\\newread\\probe\\openin\\probe=\"\(secret.path)\" \\ifeof\\probe READ-DENIED\\else SECRET-LEAK\\fi\\closein\\probe\\end{document}"
          let denied = Compiler.run(attack, name: "denied")
          check("app-file-denied", denied, denied.pages > 0 && denied.text.contains("READ-DENIED") && !denied.text.contains("SECRET-LEAK"))
          let table = Compiler.run(try Compiler.tex("# Таблица\n\n| Параметр | Значение |\n| --- | --- |\n| Лист | A4 |\n\n[Официальная ссылка](https://example.com)\n\n$\\newcommand{\\double}[1]{2#1}\\double{x}$", extra: "\\usepackage{mathtools}"), name: "table-package-link")
          check("table-package-link", table, table.pages > 0 && table.text.contains("Параметр") && table.text.contains("A4") && table.linkCount > 0)
          let invalid = Compiler.run("\\documentclass{article}\\begin{document}\\UndefinedProbeCommand\\end{document}", name: "invalid")
          check("malformed-tex", invalid, invalid.message.hasPrefix("ERROR") && invalid.elapsed < 5)
          var footprints: [UInt64] = []
          for index in 0..<10 {
            let loop = Compiler.run("\\documentclass{article}\\begin{document}\\def\\spin{\\spin}\\spin\\end{document}", name: "loop-\(index)", timeout: 1_500)
            check("deadline-\(index)", loop, loop.message.contains("interrupted") && loop.elapsed < 5)
            let result = Compiler.run(try Compiler.tex("# Правка \(index)\n\nТекст после отмены. $\\sum_{k=1}^{n} k^2$."), name: "recovered-\(index)")
            check("recovery-\(index)", result, result.pages == 1 && result.text.contains("Правка \(index)"))
            footprints.append(result.memory)
          }
          print("TYPESET_FOOTPRINT_AFTER_OPERATIONS \(footprints)")
          let report = rows.joined(separator: "\n")
          try report.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
          print("TYPESET_ACCEPTANCE_DONE \(rows.filter { $0.hasPrefix("FAIL") }.count) failures"); fflush(stdout)
        } catch { rows.append("ERROR \(error)"); print("TYPESET_ACCEPTANCE_ERROR \(error)"); fflush(stdout) }
        return (rows, url)
      }.value
      rows = output.0; url = output.1; status = rows.last ?? "Нет результата"; busy = false
    }
  }
}

@main struct ProbeApp: App {
  @State private var model = Model()
  var body: some Scene {
    WindowGroup {
      HStack {
        VStack(alignment: .leading) {
          Text("Notebook · автономный макет · прототип").font(.headline)
          TextEditor(text: $model.source).accessibilityIdentifier("source").font(.system(size: 16, design: .monospaced))
          HStack {
            Button("Сверстать", action: model.render).accessibilityIdentifier("compile").disabled(model.busy)
            Button("Проверить отмену и восстановление", action: model.acceptance).disabled(model.busy)
          }
          Text(model.status).textSelection(.enabled).accessibilityIdentifier("status")
          ScrollView { VStack(alignment: .leading) { ForEach(Array(model.rows.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) } } }.frame(maxHeight: 180)
        }.padding().frame(maxWidth: 470)
        if let url = model.url { PrintedPage(url: url) } else { ContentUnavailableView("Макет ещё не подготовлен", systemImage: "doc") }
      }.task { if ProcessInfo.processInfo.arguments.contains("--acceptance") { model.acceptance() } }
    }
  }
}
private struct PrintedPage: UIViewRepresentable {
  let url: URL
  func makeUIView(context: Context) -> PDFView { let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; return v }
  func updateUIView(_ view: PDFView, context: Context) { if view.document?.documentURL != url { view.document = PDFDocument(url: url) } }
}
