import SwiftUI

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
    case .black: (0.075, 0.082, 0.094)
    case .blue: (0.035, 0.235, 0.675)
    case .red: (0.745, 0.105, 0.125)
    case .green: (0.035, 0.405, 0.225)
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
  static let standard = Self(color: .black, width: 2.2)

  let color: PenColor
  let width: Double

  init(color: PenColor, width: Double) {
    self.color = color
    self.width = min(max(width, Self.minimumWidth), Self.maximumWidth)
  }
}
