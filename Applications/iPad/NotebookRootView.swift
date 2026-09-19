import SwiftUI
import NotebookCore

struct NotebookRootView: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var penControlsFrame = CGRect.zero

  var body: some View {
    ZStack {
    GeometryReader { geometry in
      ZStack {
        Color(red: 0.965, green: 0.957, blue: 0.925)

        switch model.loadState {
        case .loading:
          if model.awaitingAccountContent {
            VStack(spacing: 14) {
              ProgressView("Открываем ваши материалы…")
              Text(model.deviceStatusMessage).font(.callout).foregroundStyle(.secondary)
              Button("Состояние устройств") { model.openWorkspaceLibrary?(.devices) }
              if let open = model.openWorkspaceLibrary { Button("Выбрать пространство") { open(.spaces) } }
            }.padding(24)
          } else { Color.clear }
        case .ready:
          SpatialWorkspaceView()
        case .failed(let message):
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(32)
        }

        if let cue = model.actionCue {
          Text(cue)
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 38)
            .notebookPanel()
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .allowsHitTesting(false)
        }

        if let failure = model.persistenceFailure {
          VStack(alignment: .leading, spacing: 8) {
            Label("Изменения ещё не сохранены", systemImage: "exclamationmark.triangle")
              .font(.headline)
            Text(failure).font(.caption).lineLimit(3)
            Button("Повторить сохранение") { model.retryPendingPersistence() }
              .frame(minHeight: 44)
          }
          .padding(14)
          .notebookPanel(radius:NotebookChrome.cardRadius)
          .frame(maxWidth: 420)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(18)
          .accessibilityIdentifier("persistence-failure")
        }

          PenControlsView(inkOnly:model.chat?.files.window.isOpen == true && model.chat?.files.document != nil)
            .background(NotebookControlRegion(gate: model.inputGate))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { penControlsFrame = $0 }
            .frame(
              maxWidth: .infinity,
              maxHeight: .infinity,
              alignment: .topTrailing
            )
            .padding(.top, 18)
            .padding(.trailing, 18)
      }
      .task {
          await model.start(
            pageSize: NotebookAppModel.defaultPageSize,
            viewport: .init(x: geometry.size.width, y: geometry.size.height)
          )
      }
    }
    .ignoresSafeArea()
    // Only the composer follows the keyboard safe area. The drawing geometry
    // remains the full physical viewport while system input is open.
    if let chat = model.chat, chat.files.window.isOpen, chat.files.document != nil {
      GeometryReader { geometry in
        let top = max(18, penControlsFrame.maxY - geometry.frame(in: .global).minY + 12)
        NotebookCodeDocumentView(files: chat.files)
          .padding(.top, top).padding(.horizontal, 18).padding(.bottom, 18)
      }
    }
    if let chat = model.chat {
      GeometryReader { geometry in
        let origin = geometry.frame(in: .global).origin
        let top = max(18, penControlsFrame.maxY - origin.y + 12)
        // Leave the paper navigation reachable. This is window space only;
        // keyboard avoidance never publishes a SessionPresence or remounts paper.
        let available = CGRect(x: 18, y: top, width: max(44, geometry.size.width - 36),
          height: max(44, geometry.size.height - 80 - top))
        NotebookChatWindow(chat: chat, available: available)
      }
      // Both task presentations use available window space. A widget may own
      // the keyboard while the companion must remain reachable. The separate
      // drawing GeometryReader above still owns the full physical viewport.
    }

    }
    .overlay(alignment: .bottomTrailing) {
      if let voice = model.chat?.voice { NotebookVoiceSurface(voice: voice).frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true) }
    }
    .overlayPreferenceValue(NotebookToolPanelPreference.self) { panel in
      if let panel { NotebookToolPopover(panel:panel) }
    }
    .coordinateSpace(name: "notebook-window")
    .task(id: model.collaborationPreparationKey) { await model.refreshCollaborationDetails() }
    .task {
      while !Task.isCancelled {
        await model.refreshReferenceStatuses()
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
    .sheet(item: Binding(get: { model.chat?.files.notes.reviewed }, set: { model.chat?.files.notes.reviewed = $0 })) { fragment in
      if let notes = model.chat?.files.notes { NotebookCodeReviewView(notes: notes, fragment: fragment).environment(model) }
    }
    .environment(\.openURL, OpenURLAction { url in
      guard NotebookCodeLink(url: url) != nil else { return .systemAction }
      model.openNotebookLink(url); return .handled
    })
    .preferredColorScheme(.light)
  }

}
