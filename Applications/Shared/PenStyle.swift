import SwiftUI
import TetradCore

enum DrawingTool: Sendable {
  case pen
  case eraser
}

enum PenColor: String, CaseIterable, Identifiable, Sendable {
  case black
  case blue
  case red
  case green

  var id: Self { self }

  var name: String {
    switch self {
    case .black: "Чёрная"
    case .blue: "Синяя"
    case .red: "Красная"
    case .green: "Зелёная"
    }
  }

  var components: (red: Double, green: Double, blue: Double) {
    switch self {
    case .black: (0, 0, 0)
    case .blue: (0, 0.19, 0.78)
    case .red: (0.82, 0.04, 0.07)
    case .green: (0, 0.43, 0.2)
    }
  }

  var displayColor: Color {
    Color(
      red: components.red,
      green: components.green,
      blue: components.blue
    )
  }
}

struct PenStyle: Equatable, Sendable {
  static let minimumWidth = 1.0
  static let maximumWidth = 8.0
  static let lowestMinimumOpacity = 0.0
  static let highestMinimumOpacity = PencilPressureOpacity.maximumFloor
  static let standard = Self(color: .black, width: 2.2, minimumOpacity: 0.18)

  let color: PenColor
  let width: Double
  let minimumOpacity: Double

  init(color: PenColor, width: Double, minimumOpacity: Double) {
    self.color = color
    self.width = min(max(width, Self.minimumWidth), Self.maximumWidth)
    self.minimumOpacity = min(
      max(minimumOpacity, Self.lowestMinimumOpacity),
      Self.highestMinimumOpacity
    )
  }
}
