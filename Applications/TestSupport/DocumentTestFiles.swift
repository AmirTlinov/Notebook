import Foundation
import NotebookCore

/// Authoring fixtures produce the same ordinary files that the editor publishes.
/// There is no test-only document decoder or generated-source production route.
struct DocumentTestFiles {
  let id: String
  let files: [DocumentFile]
  let inclusion: String
  let initialState: JSONValue
  let height: Double

  static func tex(id: String, source: String) -> Self {
    .init(id: id, files: [.init(id: id, path: "sections/\(id).tex", source: source)],
      inclusion: "\\hypertarget{\(id)}{}\\input{sections/\(id).tex}", initialState: .null, height: 0)
  }

  static func program(id: String, html: String, css: String = "", javaScript: String = "",
    initialState: JSONValue = .object([:]), height: Double = 320, breakable: Bool = true) -> Self {
    let prefix = "programs/\(id)"
    let config: JSONValue = .object(["html": .string("index.html"), "css": .string("style.css"),
      "javaScript": .string("main.js"), "module": .bool(false), "initialState": initialState])
    let data = try! JSONEncoder().encode(config)
    let pointsToSurface = PhysicalPaper.pointsPerCentimeter * 2.54 / 72
    let files: [DocumentFile] = [
      .init(id: "\(id)-html", path: prefix + "/index.html", source: html),
      .init(id: "\(id)-css", path: prefix + "/style.css", source: css),
      .init(id: "\(id)-js", path: prefix + "/main.js",
        source: javaScript.isEmpty ? "notebook.ready(Promise.resolve());" : javaScript),
      .init(id: "\(id)-config", path: prefix + "/program.json", source: String(decoding: data, as: UTF8.self))]
    return .init(id: id, files: files,
      inclusion: "\\NotebookInteractive[id=\(id),width=\\linewidth,height=\(height / pointsToSurface)bp\(breakable ? ",breakable" : "")]{\(prefix)}",
      initialState: initialState, height: height)
  }

  static func document(id: UUID = UUID(), actor: UUID = UUID(), contents: [Self], width: Double = 595.276, height: Double = 841.89) -> DocumentDocument {
    let source = """
      \\documentclass[11pt]{article}
      \\usepackage{fontspec}
      \\setmainfont{Libertinus Serif}
      \\usepackage[paperwidth=\(width)bp,paperheight=\(height)bp,margin=36bp]{geometry}
      \\usepackage{hyperref}
      \\usepackage{notebook}
      \\setlength{\\parindent}{0pt}
      \\begin{document}
      \(contents.map(\.inclusion).joined(separator: "\n"))
      \\end{document}
      """
    return .init(id: id, actor: actor, files: [.init(id: "main", path: "main.tex", source: source)] + contents.flatMap(\.files))
  }
}
