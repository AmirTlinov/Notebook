import Foundation
import NotebookScriptWorker

guard let url = Bundle.main.url(forResource: "notebook-markup", withExtension: "js"),
  let source = try? String(contentsOf: url, encoding: .utf8) else { fatalError("Bundled Notebook parser is missing") }
let delegate = NotebookScriptService(mode: .markup, bootstrap: source)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
