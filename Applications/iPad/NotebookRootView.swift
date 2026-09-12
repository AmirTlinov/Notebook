import SwiftUI
import NotebookCore

struct NotebookRootView: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var showsPairing = false
  @State private var showsHistory = false
  @State private var sceneOrigin = CGPoint.zero
  @State private var penControlsFrame = CGRect.zero
  @State private var chatFrame = CGRect.zero
  @State private var elementControlFrames: [CGRect] = []

  var body: some View {
    ZStack {
    GeometryReader { geometry in
      ZStack {
        Color(red: 0.965, green: 0.957, blue: 0.925)

        switch model.loadState {
        case .loading:
          Color.clear
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
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.thinMaterial, in: Capsule())
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
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
          .frame(maxWidth: 420)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(18)
          .accessibilityIdentifier("persistence-failure")
        }

          PenControlsView()
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
            pageSize: PageSize(
              width: geometry.size.width,
              height: geometry.size.height
            )
          )
      }
    }
    .ignoresSafeArea()
    .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { sceneOrigin = $0 }
    .onPreferenceChange(ElementEditingControlFrames.self) { elementControlFrames = $0 }
    // Only the composer follows the keyboard safe area. The drawing geometry
    // remains the full physical viewport while system input is open.
    NotebookCollaborationView(showsHistory: $showsHistory)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
      .padding(18)
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
        NotebookChatWindow(chat: chat, available: available,
          openPairing: { showsPairing = true },
          openHistory: { showsHistory = true }, frameChanged: { chatFrame = $0 })
      }
      // The launcher stays still during keyboard dismissal. A compact editor
      // or native question follows the keyboard just like the expanded composer.
      .ignoresSafeArea(.keyboard, edges: chat.expanded || chat.compactDraftExpanded || chat.conversation?.requests.isEmpty == false ? [] : .bottom)
    }
    if let question = model.agentQuestion, model.chat?.expanded != true {
      NotebookQuestionOverlay(question: question, sceneOrigin: sceneOrigin,
        footerHeight: 0, controls: [penControlsFrame, chatFrame] + elementControlFrames).id(question.id)
    }
    }
    .overlay(alignment: .bottomTrailing) {
      if let voice = model.chat?.voice { NotebookVoiceSurface(voice: voice).frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true) }
    }
    .coordinateSpace(name: "notebook-window")
    .sheet(isPresented: $showsPairing) { NotebookPairingView().environment(model) }
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
