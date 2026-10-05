import SwiftUI
import NotebookCore

extension PenColor {
  var displayColor: Color {
    Color(
      red: components.red,
      green: components.green,
      blue: components.blue
    )
  }
}
