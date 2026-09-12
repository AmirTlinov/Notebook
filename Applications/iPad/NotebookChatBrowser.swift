import SwiftUI
import NotebookCore

/// Two projections of the native Codex catalogue. Opening a folder reads its
/// own pages; it does not change the selected conversation or project files.
struct NotebookChatBrowser: View {
  @Bindable var chat: NotebookChatController
  let openPairing: () -> Void
  let editProject: (CodexProject) -> Void
  let createInProject: (CodexProject) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(chat.pendingCreations) { job in
          Text(job.state == .uncertain
            ? "Codex не подтвердил создание чата. Запрос не отправлялся повторно."
            : "Чат создаётся на Mac…")
            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 10)
            .accessibilityIdentifier("notebook-chat-creation-" + job.id.uuidString)
        }
        if !chat.connected {
          Button("Подключить Mac", systemImage: "link", action: openPairing)
            .font(.system(size: 14)).frame(minHeight: 44).accessibilityIdentifier("notebook-chat-connect")
        }
        if chat.browserMode == .chats {
          taskRows(chat.catalogues[.chats], project: nil)
        } else {
          if chat.projects.isEmpty {
            Text(chat.connected ? "В Codex пока нет проектов." : "Проекты появятся при подключении Mac.")
              .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 12)
          }
          ForEach(chat.projects) { project in
            let expanded = chat.expandedProjects.contains(project.id)
            Button { chat.toggleProject(project) } label: {
              HStack(spacing: 10) {
                Image(systemName: expanded ? "folder.fill" : "folder").font(.system(size: 15))
                  .foregroundStyle(.secondary).frame(width: 20)
                Text(project.name).font(.system(size: 14)).lineLimit(1)
                Spacer(minLength: 0)
                if chat.catalogues[.project(project.id)]?.loading == true,
                  chat.catalogues[.project(project.id)]?.loaded != true { ProgressView().controlSize(.mini) }
              }.frame(minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityValue(expanded ? "Раскрыт" : "Свёрнут")
            .accessibilityIdentifier("notebook-chat-project-" + project.id)
            .contextMenu {
              Button("Новый чат в проекте", systemImage: "square.and.pencil") { createInProject(project) }
              Button("Настроить проект", systemImage: "slider.horizontal.3") { editProject(project) }
            }
            if expanded {
              taskRows(chat.catalogues[.project(project.id)], project: project).padding(.leading, 30)
            }
          }
          if let cursor = chat.projectCursor {
            Color.clear.frame(height: 1).id(cursor)
              .onScrollVisibilityChange { if $0 { chat.catalogueProjects(next: true) } }
          }
        }
      }.padding(.horizontal, 22).padding(.bottom, 16)
    }
    .id(chat.browserMode)
    .scrollBounceBehavior(.basedOnSize)
    .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-chat-recents")
  }

  @ViewBuilder private func taskRows(_ window: NotebookChatController.CatalogueWindow?, project: CodexProject?) -> some View {
    let tasks = window?.tasks ?? []
    if tasks.isEmpty {
      if window?.loaded == true {
        HStack {
          Text("Нет чатов").foregroundStyle(.secondary)
          Spacer(minLength: 4)
          if let project {
            Button { createInProject(project) } label: {
              Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Новый чат в «" + project.name + "»")
          }
        }.font(.system(size: 13)).frame(minHeight: 36)
          .accessibilityIdentifier("notebook-project-empty-" + (project?.id ?? "chats"))
      } else {
        Text(window?.error != nil ? "Не удалось прочитать чаты. Подключение проверяется…"
          : chat.connected ? "Загружаются чаты…" : "Mac не в сети")
          .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 10)
      }
    }
    ForEach(tasks) { task in
      Button { chat.select(task) } label: {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 3) {
            Text(task.title).font(.system(size: 14)).lineLimit(1)
            if project == nil, let name = chat.project(for: task)?.name {
              Text(name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          switch chat.activities[task.id]?.status {
          case .running: ProgressView().controlSize(.mini).accessibilityLabel("В работе")
          case .waitingForInput: Image(systemName: "bubble.left.and.exclamationmark.bubble.right").foregroundStyle(.secondary)
          default: EmptyView()
          }
        }.padding(.horizontal, 8).frame(minHeight: 44)
          .background(chat.threadID == task.id ? Color(.secondarySystemBackground) : .clear, in: RoundedRectangle(cornerRadius: 8))
          .contentShape(Rectangle())
      }.accessibilityIdentifier("notebook-chat-task-" + task.id)
    }
    if let cursor = window?.cursor {
      Color.clear.frame(height: 1).id(cursor)
        .onScrollVisibilityChange { if $0 { chat.catalogue(next: true, project: project) } }
    }
  }
}
