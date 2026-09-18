import SwiftUI

/// Window chrome only. Paper, authored content and gesture ownership stay with
/// their existing surfaces; small glyphs do not shrink the 44-point controls.
enum NotebookChrome {
  static let surface = Color(red: 252 / 255, green: 252 / 255, blue: 250 / 255)
  static let insetSurface = Color(red: 243 / 255, green: 244 / 255, blue: 241 / 255)
  static let selectionSurface = Color(red: 228 / 255, green: 230 / 255, blue: 225 / 255)
  static let border = Color.black.opacity(0.08)
  static let iconSize: CGFloat = 15
  static let controlSize: CGFloat = 44
  static let barHeight: CGFloat = 40
  static let panelRadius: CGFloat = 20
  static let cardRadius: CGFloat = 16
  static let iconFont = Font.system(size: iconSize, weight: .regular)
}

struct NotebookSurface: View {
  var radius: CGFloat = NotebookChrome.panelRadius
  var body: some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(NotebookChrome.surface)
      .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(NotebookChrome.border, lineWidth: 0.5) }
      .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
      .allowsHitTesting(false)
  }
}

extension View {
  func notebookBar() -> some View {
    font(NotebookChrome.iconFont).buttonStyle(.plain).padding(.horizontal, 4).contentShape(Rectangle())
      .background { NotebookSurface(radius: NotebookChrome.barHeight / 2).padding(.vertical, 2) }
  }

  func notebookPanel(radius: CGFloat = NotebookChrome.panelRadius) -> some View {
    clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .background { NotebookSurface(radius: radius) }
  }
}
