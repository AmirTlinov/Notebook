import SwiftUI
import NotebookCore

struct NotebookRootView: View {
  @Environment(NotebookAppModel.self) private var model

  var body: some View {
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

        NotebookCollaborationView()
          .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomLeading)
          .padding(18)

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

        #if os(iOS)
          PenControlsView()
            .frame(
              maxWidth: .infinity,
              maxHeight: .infinity,
              alignment: .topTrailing
            )
            .padding(.top, 18)
            .padding(.trailing, 18)
        #else
          Button { model.isPointing.toggle() } label: {
            Label("Указать",systemImage:"hand.point.up.left")
          }.buttonStyle(.bordered).keyboardShortcut("p",modifiers:[.command,.shift])
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing).padding(18)
        #endif
      }
      .onAppear {
        #if os(iOS)
          model.start(
            pageSize: PageSize(
              width: geometry.size.width,
              height: geometry.size.height
            )
          )
        #else
          model.start(pageSize: NotebookAppModel.defaultPageSize)
        #endif
      }
    }
    .ignoresSafeArea()
    .preferredColorScheme(.light)
  }

}
