import SwiftUI

/// The infinite workspace is a quiet desk beneath the notebooks. Its cool
/// neutral material and sparse dots keep it visually separate from warm ruled
/// paper while preserving precise spatial orientation.
enum BoardAppearance {
  static let background = Color(
    red: 0.902,
    green: 0.907,
    blue: 0.895
  )
  static let dot = Color(
    red: 0.25,
    green: 0.31,
    blue: 0.33
  ).opacity(0.18)
  static let minimumDotSpacing = 30.0
}
