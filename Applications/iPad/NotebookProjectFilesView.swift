import SwiftUI
import NotebookCore

struct NotebookProjectFilesView: View {
  @Bindable var files: NotebookFileController
  let computer: UUID?
  var attach: ((NotebookFileAddress, Bool) -> Void)? = nil
  var body: some View {
    VStack(spacing: 0) {
      if attach == nil {
        Text("Файлы").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 14)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          if let selected = files.window.selected {
            Button { if let attach { attach(selected, false) } else { Task { await files.open(selected) } } } label: {
              Label((selected.path as NSString).lastPathComponent, systemImage: "doc.text")
                .font(.system(size: 13)).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 8)
                .background(NotebookChrome.selectionSurface, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }.accessibilityLabel(attach == nil ? "Вернуться к файлу" : "Прикрепить выбранный файл").accessibilityIdentifier("notebook-file-reopen")
          }
          if let project = files.window.project, let computer {
            ForEach(project.roots, id: \.self) { root in
              let address = NotebookFileAddress(computer: computer, project: project.id, root: root, path: "")
              VStack(alignment: .leading, spacing: 0) {
                HStack {
                  Text(URL(fileURLWithPath: root).lastPathComponent).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1).padding(.vertical, 8)
                  if let attach { Spacer(); Button { attach(address, true) } label: { Image(systemName: "plus.circle").frame(width: 44, height: 44) }.accessibilityLabel("Прикрепить папку проекта") }
                }.padding(.horizontal, 8)
                folder(address, depth: 0)
              }
            }
          } else {
            Text("Выберите проект Codex, чтобы открыть его файлы.").font(.system(size: 13)).foregroundStyle(.secondary).padding(8)
          }
          if files.loading { ProgressView().padding(8) }
          if let error = files.error { Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled).padding(8) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.bottom, 8)
      }
      .scrollBounceBehavior(.basedOnSize)
      .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-project-files")
    }
    .background(NotebookChrome.insetSurface)
    .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-files-pane")
  }
  private func folder(_ address: NotebookFileAddress, depth: Int) -> AnyView {
    AnyView(VStack(alignment: .leading, spacing: 0) {
      if let directory = files.directories[address] {
        ForEach(directory.entries) { entry in
          let child = address.child(entry.name), isFolder = entry.kind == .directory
          HStack(spacing: 0) {
          Button {
            if isFolder {
              if files.expandedFolders.contains(child) { files.collapse(child) }
              else { Task { await files.expand(child) } }
            } else if let attach { attach(child, false) } else { Task { await files.open(child) } }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: isFolder ? (files.expandedFolders.contains(child) ? "folder.fill" : "folder") : (entry.kind == .symbolicLink ? "link" : "doc.text"))
                .font(.system(size: 13)).foregroundStyle(.secondary)
              Text(entry.name).font(.system(size: 13)).lineLimit(1)
              Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(min(depth, 10)) * 10).padding(.horizontal, 8)
            .frame(minHeight: 44).contentShape(Rectangle())
            .background(files.window.selected == child ? NotebookChrome.selectionSurface : .clear, in: RoundedRectangle(cornerRadius: 8))
          }
          .disabled(entry.kind == .symbolicLink || entry.kind == .unsupported)
          .accessibilityIdentifier("notebook-file-" + child.path)
          if isFolder, let attach {
            Button { attach(child, true) } label: { Image(systemName: "plus.circle").frame(width: 44, height: 44) }.accessibilityLabel("Прикрепить папку «" + entry.name + "»")
          }
          }
          if isFolder, files.expandedFolders.contains(child) { folder(child, depth: depth + 1) }
        }
        if directory.next != nil { Button("Ещё файлы…") { Task { await files.expand(address, more: true) } }.font(.system(size: 12)).frame(minHeight: 44) }
        if directory.entries.isEmpty { Text("Папка пуста").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8) }
      }
      if files.directories[address] == nil, files.loadingDirectories.contains(address) { ProgressView().controlSize(.small).padding(.vertical, 8) }
      if let error = files.directoryErrors[address] {
        Text(error).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).padding(.vertical, 8)
      }
    })
  }
}
