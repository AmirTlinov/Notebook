import CoreGraphics
import SwiftUI
import NotebookCore

struct PaperColorComponents: Sendable {
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

  /// Native vector paper and retained turn/export pixels share the same
  /// top-left geometry; the destination owns projection and physical line width.
  static func gridPath(size: CGSize) -> CGPath {
    let path = CGMutablePath()
    let spacing = PhysicalPaper.gridSpacing
    var x = 0.0
    while x <= size.width {
      path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height))
      x += spacing
    }
    var y = 0.0
    while y <= size.height {
      path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y))
      y += spacing
    }
    return path
  }
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
          Path(PaperAppearance.gridPath(size: geometry.size))
          .stroke(Color(red:PaperAppearance.grid.red,green:PaperAppearance.grid.green,
            blue:PaperAppearance.grid.blue).opacity(PaperAppearance.gridOpacity),lineWidth:1/displayScale)
        }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
