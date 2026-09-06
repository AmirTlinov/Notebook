import CoreGraphics
import Foundation
import NotebookCore
import SwiftUI

/// A quiet dyed-card palette. Its lightness keeps the default black Pencil
/// readable, and the item's UUID keeps the same material on both devices.
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
    case .oat: (0.88, 0.84, 0.73)
    case .sage: (0.73, 0.79, 0.70)
    case .clay: (0.84, 0.68, 0.57)
    case .mist: (0.71, 0.78, 0.81)
    case .rose: (0.83, 0.70, 0.70)
    case .graphite: (0.69, 0.71, 0.69)
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
    guard kind == .notebook else { return Color(red: 0.982, green: 0.977, blue: 0.951) }
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
        colors: [.white.opacity(0.14), .clear, .black.opacity(0.025)],
        startPoint: .topLeading, endPoint: .bottomTrailing
      ))
      shape.fill(ImagePaint(image: CoverPaperGrain.image, scale: 1))
        .opacity(item.kind == .notebook ? 0.48 : 0.2)
      shape.strokeBorder(LinearGradient(
        colors: [.white.opacity(0.58), .white.opacity(0.10), .black.opacity(0.15)],
        startPoint: .topLeading, endPoint: .bottomTrailing
      ), lineWidth: 1.4)

      if item.kind == .notebook {
        binding
      } else {
        Text("ДОКУМЕНТ")
          .font(.system(size: geometry.width * 0.014, weight: .medium))
          .tracking(geometry.width * 0.003)
          .foregroundStyle(Color.black.opacity(0.35))
          .offset(x: geometry.width * 0.105, y: geometry.height * 0.078)
        Rectangle()
          .fill(Color.black.opacity(0.14))
          .frame(width: geometry.width * 0.095, height: 1)
          .offset(x: geometry.width * 0.105, y: geometry.height * 0.112)
      }
    }
    .frame(width: geometry.width, height: geometry.height)
    .accessibilityHidden(true)
  }

  private var binding: some View {
    ZStack(alignment: .leading) {
      LinearGradient(stops: [
        .init(color: .black.opacity(0.09), location: 0),
        .init(color: .clear, location: 0.25),
        .init(color: .white.opacity(0.10), location: 0.60),
        .init(color: .black.opacity(0.07), location: 0.82),
        .init(color: .clear, location: 1),
      ], startPoint: .leading, endPoint: .trailing)
      Rectangle().fill(.black.opacity(0.10)).frame(width: 0.8).offset(x: 38)
      Rectangle().fill(.white.opacity(0.24)).frame(width: 0.8).offset(x: 39.2)
    }
    .frame(width: 52, height: geometry.height - 4)
    .offset(x: 2, y: 2)
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}

/// The page block stays below the moving front cover. Its narrow exposed edge
/// belongs to depth decoration; camera and input retain the sheet rectangle.
struct WorkspaceItemDepthView: View {
  let kind: WorkspaceItemKind
  let geometry: WorkspaceItemGeometry

  var body: some View {
    if kind == .notebook {
      ZStack {
        ForEach(0..<3) { layer in
          RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
            .fill(Color(red: 0.967 - Double(layer) * 0.006, green: 0.954 - Double(layer) * 0.006, blue: 0.915 - Double(layer) * 0.006))
            .overlay {
              RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
                .strokeBorder(Color(red: 0.56, green: 0.51, blue: 0.40).opacity(0.20), lineWidth: 0.7)
            }
            .offset(x: Double(3 - layer) * 1.25, y: Double(3 - layer) * 1.8)
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
        .shadow(color: .black.opacity(lifted ? 0.035 : 0.17), radius: 1.8, x: 0, y: 1.4)
        .shadow(color: .black.opacity(lifted ? 0.22 : 0.115),
          radius: lifted ? 28 : 14, x: 1.5, y: lifted ? 18 : 7)
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
