import SwiftUI
import TetradCore

struct TetradRootView: View {
  @Environment(TetradAppModel.self) private var model
  @State private var insertionEdge: Edge = .trailing

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color(red: 0.965, green: 0.957, blue: 0.925)
          .ignoresSafeArea()

        switch model.loadState {
        case .loading:
          Color.clear
        case .ready:
          if let page = model.activePage {
            PageSurface(page: page, acceptsPencil: acceptsPencil)
              .id(page.id)
              .transition(pageTransition)
          }
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
          TwoFingerNavigationInstaller(
            onNavigate: { horizontal, direction in
              navigate(horizontal: horizontal, direction: direction)
            },
            onUndo: model.undoLastDrawingAction
          )
          .allowsHitTesting(false)

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

  private var acceptsPencil: Bool {
    #if os(iOS)
      true
    #else
      false
    #endif
  }

  private var pageTransition: AnyTransition {
    let removal: Edge = insertionEdge == .trailing ? .leading : .trailing
    return .asymmetric(
      insertion: .move(edge: insertionEdge).combined(with: .opacity),
      removal: .move(edge: removal).combined(with: .opacity)
    )
  }

  private func navigate(horizontal: Bool, direction: Int) {
    insertionEdge = direction > 0 ? .trailing : .leading
    withAnimation(.smooth(duration: 0.22)) {
      if horizontal {
        model.turnPage(direction)
      } else {
        model.changeNotebook(direction)
      }
    }
  }
}
