import SwiftUI
import NotebookCore

struct NotebookProjectFilesView: View {
  @Bindable var files: NotebookFileController
  let computer: UUID?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("Файлы").font(.system(size: 13, weight: .medium))
          Spacer()
          Button { Task { await files.roots() } } label: { Image(systemName: "arrow.clockwise").frame(width: 36, height: 44) }
            .accessibilityLabel("Обновить дерево файлов").accessibilityIdentifier("notebook-files-refresh")
        }
        if let selected = files.window.selected {
          Button { Task { await files.open(selected) } } label: {
            Label((selected.path as NSString).lastPathComponent, systemImage: "doc.text")
              .font(.system(size: 12)).lineLimit(1).frame(minHeight: 44)
          }.accessibilityLabel("Вернуться к файлу").accessibilityIdentifier("notebook-file-reopen")
          Divider()
        }
        if let project = files.window.project, let computer {
          ForEach(project.roots, id: \.self) { root in
            let address = NotebookFileAddress(computer: computer, project: project.id, root: root, path: "")
            Text(URL(fileURLWithPath: root).lastPathComponent).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.vertical, 8)
            folder(address, depth: 0)
          }
        } else {
          Text("Выберите проект Codex, чтобы открыть его файлы.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 12)
        }
        if files.loading { ProgressView().padding(.vertical, 12) }
        if let error = files.error { Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled).padding(.vertical, 8) }
      }.padding(.horizontal, 10).padding(.bottom, 12)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("notebook-project-files")
  }
  private func folder(_ address: NotebookFileAddress, depth: Int) -> AnyView {
    AnyView(VStack(alignment: .leading, spacing: 0) {
      if let directory = files.directories[address] {
        ForEach(directory.entries) { entry in
          let child = address.child(entry.name), isFolder = entry.kind == .directory
          Button {
            if isFolder {
              if files.expandedFolders.contains(child) { files.collapse(child) }
              else { Task { await files.expand(child) } }
            } else { Task { await files.open(child) } }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: isFolder ? (files.expandedFolders.contains(child) ? "folder.fill" : "folder") : (entry.kind == .symbolicLink ? "link" : "doc.text"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
              Text(entry.name).font(.system(size: 12)).lineLimit(1)
              Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(min(depth, 10)) * 10).frame(minHeight: 36).contentShape(Rectangle())
            .background(files.window.selected == child ? Color.accentColor.opacity(0.1) : Color.clear)
          }
          .disabled(entry.kind == .symbolicLink || entry.kind == .unsupported)
          .accessibilityIdentifier("notebook-file-" + child.path)
          if isFolder, files.expandedFolders.contains(child) { folder(child, depth: depth + 1) }
        }
        if directory.next != nil { Button("Ещё файлы…") { Task { await files.expand(address, more: true) } }.font(.system(size: 12)).frame(minHeight: 44) }
        if directory.entries.isEmpty { Text("Папка пуста").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8) }
      }
      if files.loadingDirectories.contains(address) { ProgressView().controlSize(.small).padding(.vertical, 8) }
      if let error = files.directoryErrors[address] {
        Text(error).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).padding(.vertical, 8)
        Button("Повторить чтение") { Task { await files.expand(address) } }.font(.system(size: 12)).frame(minHeight: 44)
      }
    })
  }
}
