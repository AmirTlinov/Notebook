import CoreGraphics
import Foundation
import NotebookCore
import SwiftUI

/// Paper tones and their print colour form one cover. The writable face stays
/// light; the item's UUID keeps the same material on both devices.
enum NotebookCoverPalette: Int, CaseIterable {
  case oat, sage, clay, mist, rose, graphite

  init(itemID: UUID) {
    let hash = withUnsafeBytes(of: itemID.uuid) { bytes in
      bytes.reduce(UInt64(14_695_981_039_346_656_037)) {
        ($0 ^ UInt64($1)) &* 1_099_511_628_211
      }
    }
    self = Self(rawValue: Int(hash % UInt64(Self.allCases.count)))!
  }

  var rgb: (Double, Double, Double) {
    switch self {
    case .oat: (0.93, 0.90, 0.82)
    case .sage: (0.87, 0.89, 0.83)
    case .clay: (0.93, 0.86, 0.78)
    case .mist: (0.86, 0.89, 0.91)
    case .rose: (0.93, 0.87, 0.84)
    case .graphite: (0.86, 0.87, 0.84)
    }
  }

  var ink: Color {
    switch self {
    case .oat: Color(red: 0.20, green: 0.29, blue: 0.25)
    case .sage: Color(red: 0.23, green: 0.31, blue: 0.25)
    case .clay: Color(red: 0.39, green: 0.25, blue: 0.19)
    case .mist: Color(red: 0.22, green: 0.29, blue: 0.36)
    case .rose: Color(red: 0.36, green: 0.24, blue: 0.25)
    case .graphite: Color(red: 0.26, green: 0.29, blue: 0.27)
    }
  }
}

struct WorkspaceCoverMaterial {
  let kind: WorkspaceItemKind
  let palette: NotebookCoverPalette

  init(item: WorkspaceItem) {
    kind = item.kind
    palette = NotebookCoverPalette(itemID: item.id)
  }

  var color: Color {
    guard kind == .notebook else { return Color(red: 0.995, green: 0.992, blue: 0.982) }
    let (r, g, b) = palette.rgb
    return Color(red: r, green: g, blue: b)
  }

  var backside: CoverBacksideColor {
    guard kind == .notebook else { return .document }
    let (r, g, b) = palette.rgb
    return CoverBacksideColor(
      red: r * 0.22 + 0.975 * 0.78,
      green: g * 0.22 + 0.966 * 0.78,
      blue: b * 0.22 + 0.934 * 0.78
    )
  }
}

/// Grain is generated once at a fixed physical density. The same tiled image
/// enters a resting cover, its frozen curl raster and every portal projection.
@MainActor
private enum CoverPaperGrain {
  static let image: Image = {
    let side = 256
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    var noise: UInt64 = 0x5041504552
    for index in 0..<(side * side) {
      noise = noise &* 6_364_136_223_846_793_005 &+ 1
      let alpha = UInt8((noise >> 32) & 31)
      let light = (noise >> 40) & 1 == 0
      let channel = light ? alpha : 0
      pixels[index * 4] = channel
      pixels[index * 4 + 1] = channel
      pixels[index * 4 + 2] = channel
      pixels[index * 4 + 3] = alpha
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(
      width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )!
    return Image(decorative: image, scale: 1)
  }()
}

private struct WorkspaceCoverPaint: View {
  let item: WorkspaceItem
  let geometry: WorkspaceItemGeometry

  var body: some View {
    let material = WorkspaceCoverMaterial(item: item)
    let shape = RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
    ZStack(alignment: .topLeading) {
      shape.fill(material.color)
      shape.fill(LinearGradient(
        colors: [.white.opacity(0.10), .clear, .black.opacity(0.035)],
        startPoint: .topLeading, endPoint: .bottomTrailing
      ))
      shape.fill(ImagePaint(image: CoverPaperGrain.image, scale: 1))
        .opacity(item.kind == .notebook ? 0.20 : 0.12)
      shape.strokeBorder(LinearGradient(
        colors: [.white.opacity(0.65), .white.opacity(0.12), .black.opacity(0.22)],
        startPoint: .topLeading, endPoint: .bottomTrailing
      ), lineWidth: 1.5)

      if item.kind == .notebook {
        binding
      } else {
        LinearGradient(colors: [.black.opacity(0.055), .clear],
          startPoint: .leading, endPoint: .trailing)
          .frame(width: geometry.width * 0.018, height: geometry.height - 4)
          .offset(x: 2, y: 2)
      }
    }
    .frame(width: geometry.width, height: geometry.height)
    .clipShape(shape)
    .accessibilityHidden(true)
  }

  private var binding: some View {
    let width = geometry.width * 0.060
    return ZStack(alignment: .leading) {
      LinearGradient(stops: [
        .init(color: .black.opacity(0.08), location: 0),
        .init(color: .white.opacity(0.14), location: 0.12),
        .init(color: .clear, location: 0.40),
        .init(color: .black.opacity(0.04), location: 0.68),
        .init(color: .black.opacity(0.07), location: 0.72),
        .init(color: .white.opacity(0.18), location: 0.79),
        .init(color: .clear, location: 1),
      ], startPoint: .leading, endPoint: .trailing)
      Rectangle().fill(.black.opacity(0.06)).frame(width: 0.8).offset(x: width * 0.70)
      Rectangle().fill(.white.opacity(0.18)).frame(width: 0.8).offset(x: width * 0.79)
    }
    .frame(width: width, height: geometry.height)
  }
}

/// Printed matter stays separate from the reusable material pixels: a rename
/// does not repaint paper, and handwritten/content layers still lie above it.
struct WorkspaceCoverTitle: View {
  let item: WorkspaceItem
  let geometry: WorkspaceItemGeometry

  private var ink: Color {
    item.kind == .notebook ? NotebookCoverPalette(itemID: item.id).ink : Color(red: 0.16, green: 0.19, blue: 0.17)
  }

  var body: some View {
    if item.kind == .notebook {
      ZStack(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: geometry.width * 0.040) {
          title(alignment: .leading)
          Rectangle().fill(ink.opacity(0.65))
            .frame(width: geometry.width * 0.075, height: 1.5)
        }
        .frame(width: geometry.width * 0.70, height: geometry.height * 0.45, alignment: .topLeading)
        .offset(x: geometry.width * 0.155, y: geometry.height * 0.14)
        VStack(alignment: .leading, spacing: geometry.width * 0.025) {
          Rectangle().fill(ink.opacity(0.28)).frame(height: 1)
          imprint("ТЕТРАДЬ")
        }
        .frame(width: geometry.width * 0.70, alignment: .leading)
        .offset(x: geometry.width * 0.155, y: geometry.height * 0.865)
      }
      .frame(width: geometry.width, height: geometry.height, alignment: .topLeading)
    } else if item.kind == .document {
      ZStack(alignment: .top) {
        imprint("ДОКУМЕНТ")
          .offset(y: geometry.height * 0.10)
        title(alignment: .center)
          .frame(width: geometry.width * 0.74, height: geometry.height * 0.30, alignment: .top)
          .offset(y: geometry.height * 0.28)
        if let paper = geometry.paperSize {
          VStack(spacing: geometry.width * 0.026) {
            Rectangle().fill(ink.opacity(0.24))
              .frame(width: geometry.width * 0.09, height: 1)
            Text(paper == .a4 ? "A4" : "Letter")
              .font(.system(size: geometry.width * 0.030, weight: .medium))
              .foregroundStyle(ink.opacity(0.65))
              .accessibilityIdentifier("document-cover-format")
          }
          .offset(y: geometry.height * 0.77)
        }
      }
      .frame(width: geometry.width, height: geometry.height, alignment: .top)
    }
  }

  private func imprint(_ text: String) -> some View {
    Text(text)
      .font(.system(size: geometry.width * 0.020, weight: .medium))
      .tracking(geometry.width * 0.0035)
      .foregroundStyle(ink.opacity(0.65))
      .accessibilityHidden(true)
  }

  private func title(alignment: TextAlignment) -> some View {
    Text(item.title)
      .font(.system(size: geometry.width * (item.kind == .notebook ? 0.082 : 0.071), weight: .regular, design: .serif))
      .foregroundStyle(ink)
      .multilineTextAlignment(alignment)
      .lineSpacing(geometry.width * 0.008)
      .lineLimit(6)
      .minimumScaleFactor(0.7)
      .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
  }
}

/// The page block stays below the moving front cover. Its narrow exposed edge
/// belongs to depth decoration; camera and input retain the sheet rectangle.
struct WorkspaceItemDepthView: View {
  let kind: WorkspaceItemKind
  let geometry: WorkspaceItemGeometry

  var body: some View {
    if kind != .board {
      ZStack(alignment: .topLeading) {
        ForEach(0..<(kind == .notebook ? 3 : 2), id: \.self) { layer in
          let distance = Double((kind == .notebook ? 3 : 2) - layer)
          RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
            .fill(Color(red: 0.978, green: 0.969, blue: 0.939))
            .overlay {
              RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
                .strokeBorder(Color(red: 0.56, green: 0.51, blue: 0.40).opacity(0.25), lineWidth: 0.7)
            }
            .offset(x: distance * 1.25, y: distance * 1.8)
        }
      }
      .frame(width: geometry.width, height: geometry.height)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}

/// Material and shadow are fixed physical artwork. Camera changes reuse these
/// exact pixels through a transform, so a pinch never rerasterizes their grain,
/// rounded clipping, gradients or blur at a new screen-sized resolution.
@MainActor
enum WorkspaceCoverRaster {
  private struct Key: Hashable {
    let width: Double
    let height: Double
    let radius: Double
    let palette: Int
    let notebook: Bool
    let lifted: Bool
  }

  nonisolated static let shadowPadding = 120.0
  private static var materials: [Key: CGImage] = [:]
  private static var shadows: [Key: CGImage] = [:]

  static func material(item: WorkspaceItem, geometry: WorkspaceItemGeometry) -> CGImage {
    let key = Key(width: geometry.width, height: geometry.height,
      radius: geometry.cornerRadius,
      palette: item.kind == .notebook ? NotebookCoverPalette(itemID: item.id).rawValue : 0,
      notebook: item.kind == .notebook, lifted: false)
    if let image = materials[key] { return image }
    let renderer = ImageRenderer(content: WorkspaceCoverPaint(item: item, geometry: geometry))
    renderer.scale = 1
    let image = renderer.cgImage!
    materials[key] = image
    return image
  }

  static func shadow(geometry: WorkspaceItemGeometry, lifted: Bool) -> CGImage {
    let key = Key(width: geometry.width, height: geometry.height,
      radius: geometry.cornerRadius, palette: 0, notebook: false, lifted: lifted)
    if let image = shadows[key] { return image }
    let shape = RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
    let renderer = ImageRenderer(content:
      shape.fill(.black)
        .frame(width: geometry.width, height: geometry.height)
        .shadow(color: .black.opacity(lifted ? 0.035 : 0.18), radius: 2, x: 0, y: 1.8)
        .shadow(color: .black.opacity(lifted ? 0.22 : 0.14),
          radius: lifted ? 28 : 18, x: 1.5, y: lifted ? 18 : 10)
        .overlay { shape.fill(.black).blendMode(.destinationOut) }
        .compositingGroup()
        .padding(shadowPadding)
    )
    renderer.scale = 1
    let image = renderer.cgImage!
    shadows[key] = image
    return image
  }
}

struct WorkspaceCoverSurface: View {
  let item: WorkspaceItem
  let geometry: WorkspaceItemGeometry

  var body: some View {
    Image(decorative: WorkspaceCoverRaster.material(item: item, geometry: geometry), scale: 1)
      .resizable()
      .frame(width: geometry.width, height: geometry.height)
      .accessibilityHidden(true)
  }
}

/// A transparent shadow is a sibling beneath the live paper, Pencil and WebKit.
/// Its fixed local rectangle follows the same camera transform as the item.
struct WorkspaceItemShadow: View {
  let geometry: WorkspaceItemGeometry
  var lifted = false
  var visibility = 1.0

  var body: some View {
    Image(decorative: WorkspaceCoverRaster.shadow(geometry: geometry, lifted: lifted), scale: 1)
      .resizable()
      .frame(width: geometry.width + 2 * WorkspaceCoverRaster.shadowPadding,
        height: geometry.height + 2 * WorkspaceCoverRaster.shadowPadding)
      .frame(width: geometry.width, height: geometry.height)
      .opacity(visibility)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
