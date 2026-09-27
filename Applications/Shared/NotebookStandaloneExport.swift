import Foundation
import NotebookCore

/// A local-file transport for the same browser API. No npm, server, model engine
/// or native capability goes into the artifact. Opening it explicitly runs only
/// the selected inline author program in an opaque, network-closed iframe.
enum NotebookStandaloneExport {
  static func document(program: DocumentProgramSource, state: JSONValue, height: Double, store: NotebookStore) throws -> Data {
    let package = try store.readProgramPackage(program.programPackage)
    let entrypoints = Set([package.html, package.css, package.javaScript, program.path + "/program.json"].compactMap { $0 })
    guard package.files.allSatisfy({ entrypoints.contains($0.path) }) else {
      throw CollaborationError("export_portable_required", "Программа с зависимостями переносится целиком в .notex.")
    }
    func text(_ path: String?) throws -> String {
      guard let path else { return "" }
      guard let file = package.files.first(where: { $0.path == path }), file.byteCount <= 4*1_024*1_024 else { throw SceneRenderError.resourceLimit }
      var data = Data(), offset: Int64 = 0
      while offset < file.byteCount { let chunk = try store.readProgramFile(file, offset: offset, maxBytes: 1_048_576); data.append(chunk); offset += Int64(chunk.count) }
      guard let result = String(data: data, encoding: .utf8) else { throw SceneRenderError.resourceLimit }
      return result
    }
    let html = try text(package.html), css = try text(package.css), javaScript = try text(package.javaScript)
    func json<T: Encodable>(_ value: T) throws -> String {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return String(decoding: try encoder.encode(value), as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }
    let requiresReady = !javaScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || html.range(of: "<script", options: .caseInsensitive) != nil
    let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; form-action 'none'; base-uri 'none'; object-src 'none'; frame-src 'none'"
    let inner = """
      <!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="\(policy)">
      <style>html,body{margin:0;background:white;color:#171713;font:17px/1.42 -apple-system,BlinkMacSystemFont,sans-serif}*{box-sizing:border-box}</style>
      <script>\(NotebookProgramBridge.script)
      function failure(kind,message){
        const show=()=>{let node=document.getElementById('notebook-export-error');if(!node){node=document.createElement('pre');node.id='notebook-export-error';node.setAttribute('role','alert');node.style.cssText='white-space:pre-wrap;color:#9b3028;padding:16px';document.body.prepend(node)}node.textContent=kind+': '+String(message)};
        if(document.body)show();else addEventListener('DOMContentLoaded',show,{once:true});
      }
      window.notebookProgram=createNotebookProgram({state:\(try json(state)),report:failure});window.notebook=notebookProgram.api;
      addEventListener('error',e=>failure('runtime',e.message));addEventListener('unhandledrejection',e=>failure('runtime',e.reason));
      addEventListener('pagehide',()=>{void notebookProgram.dispose().catch(()=>{})});
      addEventListener('load',async()=>{try{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode()));await notebookProgram.start({requiresReady:\(requiresReady)});document.documentElement.dataset.programReady='NotebookProgram/1'}catch(e){failure('ready',e)}});
      const style=document.createElement('style');style.textContent=\(try json(css));document.head.append(style);
      </script></head><body>\(html)
      <script>const author=document.createElement('script');author.type=\(try json(package.module ? "module" : "text/javascript"));author.textContent=\(try json(javaScript));document.body.append(author);</script></body></html>
      """
    // The outer page has no script and never exposes a file:// origin to author
    // code. Its frame policy also refuses navigation out of about:srcdoc.
    let escaped = inner.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    let data = Data("""
      <!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src about:; base-uri 'none'; form-action 'none'">
      <title>Notebook — сохранённый интерактив</title><style>html,body{margin:0;background:white}iframe{display:block;border:0;width:100%;min-height:100vh;height:\(height)px}</style></head>
      <body><iframe title="Сохранённая программа Notebook" sandbox="allow-scripts" srcdoc="\(escaped)"></iframe></body></html>
      """.utf8)
    guard data.count <= 8*1024*1024 else { throw CollaborationError("export_portable_required", "Standalone HTML превышает 8 МиБ; нужен переносимый пакет.") }
    return data
  }
}
