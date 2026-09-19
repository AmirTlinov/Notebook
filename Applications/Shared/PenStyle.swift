import SwiftUI
import NotebookCore

enum PenColor: String, CaseIterable, Identifiable, Codable, Sendable {
  case black
  case blue
  case red
  case green
  case yellow

  var id: Self { self }

  var name: String {
    switch self {
    case .black: "Чёрная"
    case .blue: "Синяя"
    case .red: "Красная"
    case .green: "Зелёная"
    case .yellow: "Жёлтая"
    }
  }

  var components: (red: Double, green: Double, blue: Double) {
    switch self {
    case .black: (0, 0, 0)
    case .blue: (0, 0.19, 0.78)
    case .red: (0.82, 0.04, 0.07)
    case .green: (0, 0.43, 0.2)
    case .yellow: (1, 0.83, 0.05)
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
  static let minimumWidth = 0.25
  static let maximumWidth = 128.0
  static let lowestMinimumOpacity = 0.0
  static let highestMinimumOpacity = PencilPressureOpacity.maximumFloor
  static let standard = Self(color: .black, width: 2.2, minimumOpacity: 0.18)

  enum Kind: Sendable { case pen, marker }
  let kind: Kind
  let color: PenColor
  let width: Double
  let minimumOpacity: Double

  init(color: PenColor, width: Double, minimumOpacity: Double, kind: Kind = .pen) {
    self.kind = kind
    self.color = color
    self.width = min(max(width, Self.minimumWidth), Self.maximumWidth)
    self.minimumOpacity = min(
      max(minimumOpacity, Self.lowestMinimumOpacity),
      kind == .marker ? 0.65 : Self.highestMinimumOpacity
    )
  }
  func opacity(force: Double) -> Double {
    kind == .marker ? minimumOpacity : PencilPressureOpacity.value(force:force,minimum:minimumOpacity)
  }
}

struct EraserStyle: Equatable, Sendable {
  static let minimumSelectableWidth = 2.0
  /// Twenty notebook cells, or ten physical centimetres on a full-size iPad.
  static let maximumSelectableWidth = PhysicalPaper.gridSpacing * 20
  static let standard = Self(maximumWidth: 14.0)

  let maximumWidth: Double

  init(maximumWidth: Double) {
    self.maximumWidth = min(
      max(maximumWidth, Self.minimumSelectableWidth),
      Self.maximumSelectableWidth
    )
  }
}
