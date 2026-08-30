import SwiftUI
import TetradCore

struct TetradRootView: View {
  @Environment(TetradAppModel.self) private var model

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

        #if os(iOS)
          PenControlsView()
            .frame(
              maxWidth: .infinity,
              maxHeight: .infinity,
              alignment: .topTrailing
            )
            .padding(.top, 18)
            .padding(.trailing, 18)
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
          model.start(pageSize: TetradAppModel.defaultPageSize)
        #endif
      }
    }
    .ignoresSafeArea()
    .preferredColorScheme(.light)
  }

}
