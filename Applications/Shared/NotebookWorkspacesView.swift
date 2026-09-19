import SwiftUI
import CloudKit

enum NotebookWorkspaceTab: String, CaseIterable { case spaces = "Пространства", devices = "Устройства" }

/// Space lifecycle belongs to launch; this view never creates or deletes stores.
struct NotebookWorkspacesView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Bindable var launch: NotebookApplicationLaunch
  var close: (() -> Void)?
  @State private var deviceQuery = ""
  @State private var editor: Editor?
  @State private var removal: Removal?
  private struct Editor: Identifiable { let id = UUID(); let spaceID: UUID?; var name: String }
  private struct Removal: Identifiable { let space: NotebookApplicationLaunch.Workspace; let everywhere: Bool; var id: UUID { space.id } }

  var body: some View {
    NavigationStack {
      VStack(spacing:0) {
        if launch.model != nil {
          Picker("Раздел",selection:$launch.workspaceTab) {
            ForEach(NotebookWorkspaceTab.allCases,id:\.self) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented).padding().accessibilityIdentifier("workspace-tabs")
        }
        if launch.workspaceTab == .devices, let model = launch.model {
          Form { NotebookDevicesContent(model:model,query:deviceQuery) }
            .searchable(text:$deviceQuery,prompt:"Найти устройство")
            .accessibilityIdentifier("workspace-devices")
        } else { workspaceList }
      }
      .navigationTitle("Пространства")
      .toolbar {
        if let close, launch.model != nil { ToolbarItem(placement: .confirmationAction) { Button("Готово", action: close) } }
      }
      .task { await launch.refreshWorkspaces() }
    }
  }

  private var workspaceList: some View {
      List {
        if let error = launch.workspaceError ?? launch.catalogError {
          Section { Text(error).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("workspace-error") }
        }
        if launch.workspaceList.isEmpty {
          ContentUnavailableView("Ваши пространства", systemImage: "square.stack.3d.up",
            description: Text("Отдельные тетради, доски и документы. Создайте пространство для работы или личных заметок."))
        }
        ForEach(launch.workspaceList) { space in
          HStack {
            Button {
              Task { await launch.openWorkspace(space.id) }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: space.local ? "square.stack.3d.up" : "icloud.and.arrow.down")
                VStack(alignment: .leading, spacing: 4) {
                  Text(space.name).foregroundStyle(.primary)
                  Text(space.deleting ? "Удаление ожидает завершения" : space.local ? "На этом устройстве" : "В iCloud")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if launch.selectedWorkspaceID == space.id { Image(systemName: "checkmark") }
              }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(space.deleting)
              .accessibilityIdentifier("workspace-open-" + space.id.uuidString)
            Menu {
              if !space.deleting {
                Button("Переименовать") { editor = .init(spaceID: space.id, name: space.name) }
                if space.local {
                  Button("Удалить с этого устройства…", role: .destructive) { removal = .init(space: space, everywhere: false) }
                }
              }
              if space.remote || space.deleting {
                Button(space.deleting ? "Завершить удаление…" : "Удалить везде…", role: .destructive) {
                  removal = .init(space: space, everywhere: true)
                }
              }
            } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36).contentShape(Rectangle()) }
              .accessibilityLabel("Действия: " + space.name)
              .accessibilityIdentifier("workspace-actions-" + space.id.uuidString)
          }
        }
        Section {
          Button { editor = .init(spaceID: nil, name: "") } label: { Label("Новое пространство", systemImage: "plus") }
            .accessibilityIdentifier("workspace-create")
        } footer: {
          Text("Материалы разных пространств не смешиваются. Ваши устройства подключаются автоматически внутри открытого пространства.")
        }
      }
      .disabled(launch.isChecking)
      .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await launch.refreshWorkspaces() } } }
      .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in Task { await launch.refreshWorkspaces() } }
      .onChange(of: launch.model?.accountConnection?.spaces) { _, _ in Task { await launch.refreshWorkspaces() } }
      .sheet(item: $editor) { value in
        WorkspaceNameEditor(launch: launch, spaceID: value.spaceID, name: value.name)
      }
      .alert(removal?.everywhere == true ? "Удалить пространство везде?" : "Удалить с этого устройства?",
        isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { value in
        Button("Удалить", role: .destructive) {
          Task { await launch.removeWorkspace(value.space.id, everywhere: value.everywhere); await launch.refreshWorkspaces() }
          removal = nil
        }
        Button("Отмена", role: .cancel) { removal = nil }
      } message: { value in
        Text(value.everywhere
          ? "«\(value.space.name)»: материалы будут удалены из iCloud и с ваших устройств после их подключения. Это нельзя отменить."
          : value.space.remote
            ? "Локальная копия «\(value.space.name)» будет удалена. Сохранённая копия в iCloud и другие устройства останутся; неотправленные изменения будут потеряны."
            : "«\(value.space.name)» и все материалы на этом устройстве будут удалены. Это нельзя отменить.")
      }
  }
}

private struct WorkspaceNameEditor: View {
  @Environment(\.dismiss) private var dismiss
  let launch: NotebookApplicationLaunch
  let spaceID: UUID?
  @State private var name: String
  @State private var error: String?
  @State private var saving = false
  private var creating: Bool { spaceID == nil }

  init(launch: NotebookApplicationLaunch, spaceID: UUID?, name: String) {
    self.launch = launch; self.spaceID = spaceID
    // The draft belongs to this presentation, not to later catalog updates.
    _name = State(initialValue: name)
  }
  var body: some View {
    NavigationStack {
      Form {
        TextField("Название", text: $name).accessibilityIdentifier("workspace-name")
          .onSubmit { submit() }
        if let error { Text(error).foregroundStyle(.secondary).accessibilityIdentifier("workspace-name-error") }
      }
      .navigationTitle(creating ? "Новое пространство" : "Название пространства")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving) }
        ToolbarItem(placement: .confirmationAction) {
          Button(creating ? "Создать" : "Сохранить") { submit() }
            .disabled(saving || (try? NotebookWorkspaceLibrary.name(name)) == nil)
            .accessibilityIdentifier("workspace-name-save")
        }
      }
    }
    .frame(minWidth: 320, minHeight: 180)
    .presentationDetents([.medium])
    .interactiveDismissDisabled(saving)
  }
  private func submit() {
    guard !saving, (try? NotebookWorkspaceLibrary.name(name)) != nil else { return }
    saving = true
    error = nil
    Task {
      let saved: Bool
      if let spaceID { saved = await launch.renameWorkspace(spaceID, name: name) }
      else { saved = await launch.createWorkspace(name: name) }
      saving = false
      if saved { dismiss() } else { error = launch.workspaceError }
    }
  }
}
