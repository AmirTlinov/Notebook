import SwiftUI
import NotebookCore

struct NotebookChatResources: View {
  let chat: NotebookChatController
  let kind: CodexResourceKind
  let added: () -> Void
  @State private var rows: [CodexComposerResource] = []
  @State private var cursor: String?
  @State private var loading = false
  @State private var notice: String?
  @State private var search = ""
  private var scope: String { "\(chat.computerID?.uuidString ?? "")/\(chat.threadID ?? "")/\(chat.connected)" }
  private var title: String { switch kind { case .plugins: "Плагины"; case .skills: "Навыки"; case .apps: "Приложения" } }
  var body: some View {
    List {
      ForEach(rows.filter { search.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(search) }) { row in
        Button {
          chat.attach(row.attachment); added()
        } label: {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.attachment.icon).frame(width: 20).padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
              Text(row.title).font(.system(size: 14))
              Text(row.enabled ? row.detail : "Недоступно или выключено в Codex").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
          }.padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.disabled(!row.enabled || chat.attachments.count >= 16)
          .accessibilityIdentifier("notebook-chat-resource-" + row.attachment.name)
      }
      if loading { ProgressView().frame(maxWidth: .infinity) }
      if cursor != nil, !loading { Color.clear.frame(height: 1).onAppear { Task { await read(next: true) } } }
      if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
      if rows.isEmpty, !loading, notice == nil { Text("В Codex нет доступных элементов.").foregroundStyle(.secondary) }
    }.listStyle(.plain).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
      .searchable(text: $search, prompt: "Найти")
      .task(id: scope) { rows = []; cursor = nil; await read(next: false) }
  }
  private func read(next: Bool) async {
    guard !loading else { return }
    guard chat.connected, let thread = chat.threadID, !chat.browsesChats else { notice = "Выберите подключённый разговор Codex."; return }
    let scope = scope, requestedCursor = next ? cursor : nil
    loading = true; defer { loading = false }
    do {
      guard case .resources(let page) = try await chat.directQuery(.resources(threadID: thread, kind: kind, cursor: requestedCursor)),
        page.nextCursor == nil || page.nextCursor != requestedCursor else { throw NotebookTransportError.invalidAcknowledgement }
      guard !Task.isCancelled, self.scope == scope else { return }
      rows = (next ? rows : []) + page.resources.filter { row in !next || !rows.contains(where: { $0.id == row.id }) }
      cursor = page.nextCursor; notice = page.notice
    } catch { if self.scope == scope, !Task.isCancelled { notice = error.localizedDescription } }
  }
}

struct NotebookChatFileAttachments: View {
  let chat: NotebookChatController
  let added: () -> Void
  var body: some View {
    NotebookProjectFilesView(files: chat.files, computer: chat.computerID) { address, folder in
      guard address.computer == chat.computerID else { return }
      let path = address.path.isEmpty ? address.root : URL(fileURLWithPath: address.root).appendingPathComponent(address.path).path
      chat.attach(.init(kind: folder ? .folder : .file, name: URL(fileURLWithPath: path).lastPathComponent, path: path)); added()
    }
    .navigationTitle("Файлы и папки на Mac").navigationBarTitleDisplayMode(.inline)
    .task { await chat.files.roots() }
  }
}
