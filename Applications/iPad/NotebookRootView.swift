import SwiftUI
import NotebookCore

struct NotebookRootView: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var showsPairing = false
  @State private var sceneOrigin = CGPoint.zero
  @State private var collaborationHeight: CGFloat = 0
  @State private var penControlsFrame = CGRect.zero
  @State private var pairingFrame = CGRect.zero
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

          Button { showsPairing = true } label: {
            Label(model.isPeerConnected ? "Mac подключён" : "Подключить Mac",
              systemImage: model.isPeerConnected ? "checkmark.shield" : "link")
              .labelStyle(.iconOnly)
              .frame(width: 44, height: 44)
              .background(.regularMaterial, in: Circle())
          }
          .background(NotebookControlRegion(gate: model.inputGate))
          .accessibilityIdentifier("pairing-settings")
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pairingFrame = $0 }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          .padding(.trailing, 18).padding(.bottom, 80)
          .sheet(isPresented: $showsPairing) { NotebookPairingView().environment(model) }
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
    NotebookCollaborationView()
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { collaborationHeight = $0 }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
      .padding(18)
    if let chat = model.chat {
      GeometryReader { geometry in
        NotebookChatPanel(chat: chat, maximumHeight: geometry.size.height - 36)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(18)
      }
    }
    if let question = model.agentQuestion, model.chat?.expanded != true {
      NotebookQuestionOverlay(question: question, sceneOrigin: sceneOrigin,
        footerHeight: collaborationHeight, controls: [penControlsFrame, pairingFrame] + elementControlFrames).id(question.id)
    }
    }
    .preferredColorScheme(.light)
  }

}
