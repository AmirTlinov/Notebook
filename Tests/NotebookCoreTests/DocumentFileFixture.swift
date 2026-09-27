import Foundation
@testable import NotebookCore

/// Ordinary files, shared by tests that exercise another content owner with a
/// document program present. No block model or generated editable copy exists.
func documentProgramFiles(id: String, html: String, initialState: JSONValue = .object([:]), path: String = "programs/model") throws -> [DocumentFile] {
  let config = JSONValue.object(["html": .string("index.html"), "css": .null, "javaScript": .null, "initialState": initialState])
  return [
    .init(id: "main", path: "main.tex", source: "\\documentclass{article}\n\\usepackage{notebook}\n\\begin{document}\n\\NotebookInteractive[id={\(id)},width=200pt,height=100pt]{\(path)}\n\\end{document}"),
    .init(id: id, path: path + "/index.html", source: html),
    .init(id: id + "-config", path: path + "/program.json", source: String(decoding: try JSONEncoder().encode(config), as: UTF8.self))
  ]
}
