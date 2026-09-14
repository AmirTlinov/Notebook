import Foundation
import NotebookScriptWorker

guard let url = Bundle.main.url(forResource: "notebook-sdk", withExtension: "js"),
  let source = try? String(contentsOf: url, encoding: .utf8) else { fatalError("Bundled Notebook SDK is missing") }
let delegate = NotebookScriptService(mode: .user, bootstrap: source)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
