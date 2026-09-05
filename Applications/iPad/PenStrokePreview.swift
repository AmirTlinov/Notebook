import NotebookCore
import PencilKit
import SwiftUI

/// The settings show the actual ink engine at the selected width and pressure response.
struct PenStrokePreview: View {
  let style: PenStyle
  @State private var image: UIImage?

  var body: some View {
    VStack(spacing: 0) {
      if let image { Image(uiImage: image).resizable().frame(height: 30) }
      Text("Легко → с нажимом").font(.caption2).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .task(id: "\(style.color.rawValue)|\(style.width)|\(style.minimumOpacity)") {
      let style = style
      let raster = await Task.detached(priority: .utility) {
        let points: [PKStrokePoint] = (0..<80).map { index in
          let t = Double(index) / 79
          return PKStrokePoint(
            location: .init(x: 8 + t * 144, y: 15 + sin(t * .pi * 3) * 6),
            timeOffset: t, size: .init(width: style.width, height: style.width),
            opacity: PencilPressureOpacity.value(force: t, minimum: style.minimumOpacity),
            force: t, azimuth: 0, altitude: .pi / 2)
        }
        let rgb = style.color.components
        let action = PageInkAction(
          tool: .pen, color: .init(red: rgb.red, green: rgb.green, blue: rgb.blue), points: points)
        return InkRasterRenderer.shared.page(
          PageInkDrawing(actions: [action]), size: .init(width: 160, height: 30))
      }.value
      guard !Task.isCancelled else { return }
      image = raster.map { UIImage(cgImage: $0) }
    }
    .accessibilityLabel("Образец линии от слабого до сильного нажима")
    .accessibilityIdentifier("pen-stroke-preview")
  }
}
