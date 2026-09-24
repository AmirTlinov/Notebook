import SwiftUI

/// Tool state stays in PenControlsView. Only its anchored presentation crosses
/// to the window overlay, inside SwiftUI's supported view hierarchy.
struct NotebookToolPanelPreference: PreferenceKey {
  struct Panel {
    let toolbar: Anchor<CGRect>
    let anchor: UnitPoint
    let content: AnyView
    let dismiss: () -> Void
  }
  static var defaultValue: Panel? { nil }
  static func reduce(value: inout Panel?, nextValue: () -> Panel?) { value = nextValue() ?? value }
}

struct NotebookToolPopover: View {
  @Environment(NotebookAppModel.self) private var model
  let panel: NotebookToolPanelPreference.Panel

  var body: some View {
    GeometryReader { geometry in
      let toolbar = geometry[panel.toolbar]
      ZStack(alignment:.topLeading) {
        OutsideToolbar(toolbar:toolbar)
          .fill(.clear,style:.init(eoFill:true))
          .contentShape(OutsideToolbar(toolbar:toolbar),eoFill:true)
          .onTapGesture(perform:panel.dismiss)
          .background(NotebookControlRegion(gate:model.inputGate))
          .accessibilityHidden(true)
        AnchoredPanel(toolbar:toolbar,anchor:panel.anchor,safeArea:geometry.safeAreaInsets) {
          panel.content
            .background(NotebookChrome.surface,in:RoundedRectangle(cornerRadius:10))
            .overlay { RoundedRectangle(cornerRadius:10).strokeBorder(.primary.opacity(0.14),lineWidth:0.5) }
            .compositingGroup()
            .shadow(color:.black.opacity(0.12),radius:8,x:0,y:3)
            .background(NotebookControlRegion(gate:model.inputGate))
        }
      }
    }
    .ignoresSafeArea()
  }

  /// The original touch reaches the real toolbar button. Everywhere else an
  /// outside tap only dismisses; it does not draw or move the underlying scene.
  private struct OutsideToolbar: Shape {
    let toolbar: CGRect
    func path(in rect: CGRect) -> Path {
      Path { $0.addRect(rect); $0.addRect(toolbar) }
    }
  }

  private struct AnchoredPanel: Layout {
    let toolbar: CGRect
    let anchor: UnitPoint
    let safeArea: EdgeInsets

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
      guard let content = subviews.first else { return }
      let limits = CGRect(x:bounds.minX+safeArea.leading+8,y:bounds.minY+safeArea.top+8,
        width:max(1,bounds.width-safeArea.leading-safeArea.trailing-16),
        height:max(1,bounds.height-safeArea.top-safeArea.bottom-16))
      let fitted = content.sizeThatFits(.init(width:limits.width,height:limits.height))
      let size = CGSize(width:min(fitted.width,limits.width),height:min(fitted.height,limits.height))
      let point = CGPoint(x:toolbar.minX+toolbar.width*anchor.x,y:toolbar.minY+toolbar.height*anchor.y)
      let x = min(max(limits.minX,point.x-size.width/2),limits.maxX-size.width)
      let y = point.y+6+size.height <= limits.maxY ? point.y+6 : max(limits.minY,point.y-size.height-6)
      content.place(at:.init(x:x,y:y),anchor:.topLeading,proposal:.init(size))
    }
  }
}
