import SwiftUI
import NotebookCore

struct NotebookRootView: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var topBarFrame = CGRect.zero
  @State private var documentMode = DocumentViewMode.paper
  @State private var chromeHidden = false
  #if DEBUG
    @State private var remoteProofPhase: String?
  #endif

  private var chatStaysVisible: Bool {
    model.chat?.expanded == true || model.chat?.conversation?.requests.isEmpty == false
      || model.chat?.voice.error != nil || model.chat?.dictation.notice != nil
  }

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
          DocumentSourceWorkspace(mode: $documentMode, topInset: max(74, topBarFrame.maxY - geometry.frame(in: .global).minY + 8),
            allowsBeside: geometry.size.width > geometry.size.height) { SpatialWorkspaceView(chromeHidden:$chromeHidden,documentMode:$documentMode) }
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

        if model.presence != nil {
          NotebookTopBar()
            .background(NotebookControlRegion(gate:model.inputGate))
            .opacity(chromeHidden ? 0 : 1).allowsHitTesting(!chromeHidden)
            .accessibilityHidden(chromeHidden).environment(\.notebookChromeVisible,!chromeHidden)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { topBarFrame = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.horizontal, 18).padding(.top, 18)
        }

      }
      .task {
          await model.start(
            pageSize: NotebookAppModel.defaultPageSize,
            viewport: .init(x: geometry.size.width, y: geometry.size.height)
          )
          #if DEBUG
            await NotebookPhysicalRemoteProof.runIfRequested(model) { remoteProofPhase = $0 }
          #endif
      }
      #if DEBUG
        .overlay(alignment: .bottomLeading) {
          if let remoteProofPhase {
            Text(NotebookPhysicalRemoteProof.title(remoteProofPhase)).font(.caption)
              .padding(10).background(.regularMaterial).padding()
              .accessibilityIdentifier("notebook-remote-proof-phase")
          }
        }
      #endif
    }
    .ignoresSafeArea()
    // Only the composer follows the keyboard safe area. The drawing geometry
    // remains the full physical viewport while system input is open.
    if let chat = model.chat, chat.files.window.isOpen, chat.files.document != nil {
      GeometryReader { geometry in
        let top = max(18, topBarFrame.maxY - geometry.frame(in: .global).minY + 12)
        NotebookCodeDocumentView(files: chat.files)
          .padding(.top, top).padding(.horizontal, 18).padding(.bottom, 18)
      }
    }
    if let chat = model.chat {
      GeometryReader { geometry in
        let origin = geometry.frame(in: .global).origin
        let top = max(18, topBarFrame.maxY - origin.y + 12)
        // Leave the paper navigation reachable. This is window space only;
        // keyboard avoidance never publishes a SessionPresence or remounts paper.
        let available = CGRect(x: 18, y: top, width: max(44, geometry.size.width - 36),
          height: max(44, geometry.size.height - 80 - top))
        NotebookChatWindow(chat:chat,available:available)
          .opacity(chromeHidden && !chatStaysVisible ? 0 : 1)
          .allowsHitTesting(!chromeHidden || chatStaysVisible)
          .accessibilityHidden(chromeHidden && !chatStaysVisible)
          .environment(\.notebookChromeVisible,!chromeHidden || chatStaysVisible)
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
