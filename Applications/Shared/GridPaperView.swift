import SwiftUI
import TetradCore

struct GridPaperView: View {
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    Canvas(opaque: true, colorMode: .nonLinear) { context, size in
      context.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .color(Color(red: 0.992, green: 0.988, blue: 0.969))
      )
      let spacing = PhysicalPaper.pointsPerCentimeter
      var grid = Path()
      var x = 0.0
      while x <= size.width {
        grid.move(to: CGPoint(x: x, y: 0))
        grid.addLine(to: CGPoint(x: x, y: size.height))
        x += spacing
      }
      var y = 0.0
      while y <= size.height {
        grid.move(to: CGPoint(x: 0, y: y))
        grid.addLine(to: CGPoint(x: size.width, y: y))
        y += spacing
      }
      context.stroke(
        grid,
        with: .color(
          Color(red: 0.31, green: 0.49, blue: 0.67).opacity(0.105)
        ),
        lineWidth: 1 / displayScale
      )
    }
  }
}
