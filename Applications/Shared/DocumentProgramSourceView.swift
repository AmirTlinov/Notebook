import Foundation
import NotebookCore
import SwiftUI

/// A bounded view of the existing immutable package, never a second source store.
enum DocumentProgramSourceText {
  static let pageBytes = 256 * 1024
  static func isText(_ file: NotebookProgramPackage.File) -> Bool {
    file.mimeType.hasPrefix("text/") || ["application/json", "application/x-tex", "image/svg+xml", "model/gltf+json"].contains(file.mimeType)
      || ["ts", "tsx", "jsx", "md", "wgsl", "glsl", "vert", "frag", "yaml", "yml", "toml"].contains((file.path as NSString).pathExtension.lowercased())
  }
  static func read(_ file: NotebookProgramPackage.File, page: Int, store: NotebookStore) throws -> String {
    let offset = min(file.byteCount, Int64(max(0, page)) * Int64(pageBytes))
    let bytes = try store.readProgramFile(file, offset: offset, maxBytes: pageBytes + 3)
    return try decodePage(bytes)
  }
  static func decodePage(_ bytes: Data) throws -> String {
    // Adjacent pages meet at the same UTF-8 boundary, without dropped glyphs.
    var start = 0, end = min(pageBytes, bytes.count)
    while start < bytes.count, bytes[start] & 0xc0 == 0x80 { start += 1 }
    while end < bytes.count, bytes[end] & 0xc0 == 0x80 { end += 1 }
    guard let text = String(data: bytes.subdata(in: start..<max(start, end)), encoding: .utf8) else {
      throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return text
  }
}

struct DocumentProgramSourceView: View {
  let block: DocumentBlock
  let store: NotebookStore
  let findRequest: Int
  @State private var package: NotebookProgramPackage?
  @State private var selected = "JavaScript"
  @State private var page = 0
  @State private var text: String?
  @State private var failure: String?
  @State private var retry = 0
  private var inline: [(String, String)] { [("HTML", block.html), ("CSS", block.css), ("JavaScript", block.javaScript)] }
  private var file: NotebookProgramPackage.File? { package?.files.first { $0.path == selected } }
  private var pageCount: Int { max(1, Int(((file?.byteCount ?? 0) + Int64(DocumentProgramSourceText.pageBytes) - 1) / Int64(DocumentProgramSourceText.pageBytes))) }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        if package != nil || block.programPackage == nil {
          Picker("Файл программы", selection: $selected) {
            if let package { ForEach(package.files, id: \.path) { Text($0.path).tag($0.path) } }
            else { ForEach(inline, id: \.0) { Text($0.0).tag($0.0) } }
          }.accessibilityIdentifier("document-program-source-file")
        }
        if let file { Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)).foregroundStyle(.secondary) }
      }.padding(12)
      if let failure {
        ContentUnavailableView {
          Label("Исходник недоступен", systemImage: "exclamationmark.triangle")
        } description: { Text(failure) } actions: { Button("Повторить") { retry += 1 } }
      } else if let file, !DocumentProgramSourceText.isText(file) {
        ContentUnavailableView("Двоичный ресурс", systemImage: "doc", description: Text("\(file.path)\n\(file.mimeType)\n\(file.byteCount) байт"))
      } else if let text {
        DocumentNativeSourceViewer(text: text, findRequest: findRequest)
          .accessibilityIdentifier("document-program-source-viewer")
      } else { ProgressView("Читаем исходник…").frame(maxWidth: .infinity, maxHeight: .infinity) }
      if pageCount > 1, let file, DocumentProgramSourceText.isText(file) {
        HStack {
          Button("Предыдущая часть") { page -= 1 }.disabled(page == 0)
          Text("\(page + 1) / \(pageCount)").monospacedDigit()
          Button("Следующая часть") { page += 1 }.disabled(page + 1 == pageCount)
        }.padding(8)
      }
      Text("Исполняемый исходник · только чтение. LaTeX задаёт место на листе, программу исполняет Notebook.")
        .font(.caption).foregroundStyle(.secondary).padding(12)
    }
    .task(id: "\(block.programPackage ?? "inline"):\(retry)") {
      package = nil; failure = nil
      guard let hash = block.programPackage else { selected = "JavaScript"; return }
      do {
        let value = try await Task.detached { [store] in try store.readProgramPackage(hash) }.value
        try Task.checkCancellation(); package = value
        selected = value.javaScript ?? value.html ?? value.files[0].path
      } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
    .task(id: ReadKey(block: block, path: selected, page: page, package: package)) {
      text = nil; failure = nil
      guard block.programPackage != nil else { text = inline.first { $0.0 == selected }?.1 ?? ""; return }
      guard let file else { return }
      guard DocumentProgramSourceText.isText(file) else { return }
      do {
        let page = page
        let value = try await Task.detached { [store] in try DocumentProgramSourceText.read(file, page: page, store: store) }.value
        try Task.checkCancellation(); text = value
      } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
    .onChange(of: selected) { _, _ in page = 0 }
  }
  private struct ReadKey: Equatable {
    let block: DocumentBlock
    let path: String
    let page: Int
    let package: NotebookProgramPackage?
  }
}
