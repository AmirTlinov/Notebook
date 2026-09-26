import SwiftUI
import NotebookCore

struct PaperColorComponents {
  let red: Double
  let green: Double
  let blue: Double
}

enum PaperAppearance {
  static let background = PaperColorComponents(
    red: 0.992,
    green: 0.988,
    blue: 0.969
  )
  static let grid = PaperColorComponents(
    red: 0.31,
    green: 0.49,
    blue: 0.67
  )
  static let gridOpacity = 0.105
}

struct GridPaperView: View {
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    // Native camera projection keeps canonical paper bounds. Vector display-list
    // primitives scale with that owner; Canvas clips its local drawing using the
    // already projected hosting-view exposure and can omit the far paper cells.
    GeometryReader { geometry in
      Color(red:PaperAppearance.background.red,green:PaperAppearance.background.green,
        blue:PaperAppearance.background.blue)
        .overlay {
          Path { grid in
            let spacing=PhysicalPaper.gridSpacing
            var x=0.0
            while x <= geometry.size.width {
              grid.move(to:.init(x:x,y:0));grid.addLine(to:.init(x:x,y:geometry.size.height))
              x += spacing
            }
            var y=0.0
            while y <= geometry.size.height {
              grid.move(to:.init(x:0,y:y));grid.addLine(to:.init(x:geometry.size.width,y:y))
              y += spacing
            }
          }
          .stroke(Color(red:PaperAppearance.grid.red,green:PaperAppearance.grid.green,
            blue:PaperAppearance.grid.blue).opacity(PaperAppearance.gridOpacity),lineWidth:1/displayScale)
        }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
