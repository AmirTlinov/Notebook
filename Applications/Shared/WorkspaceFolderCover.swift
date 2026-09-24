import NotebookCore
import SwiftUI

/// The folder occupies the existing board-item geometry. Its tab, material and
/// shadow share one outline; no book binding or content thumbnails are painted.
struct WorkspaceCoverOutline: Shape {
  let kind: WorkspaceItemKind
  let cornerRadius: Double
  var hasContents = false

  func path(in rect: CGRect) -> Path {
    guard kind == .board else {
      return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
    }
    let w = rect.width, h = rect.height, r = min(cornerRadius, w * 0.03)
    let top = h * 0.08
    var path = Path()
    path.move(to: CGPoint(x: 0, y: r))
    path.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero)
    path.addLine(to: CGPoint(x: w * 0.40, y: 0))
    path.addQuadCurve(to: CGPoint(x: w * 0.44, y: r), control: CGPoint(x: w * 0.43, y: 0))
    path.addLine(to: CGPoint(x: w * 0.49, y: top))
    path.addLine(to: CGPoint(x: w - r, y: top))
    path.addQuadCurve(to: CGPoint(x: w, y: top + r), control: CGPoint(x: w, y: top))
    path.addLine(to: CGPoint(x: w, y: h - r))
    path.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
    path.addLine(to: CGPoint(x: r, y: h))
    path.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
    path.closeSubpath()
    path = path.offsetBy(dx: rect.minX, dy: rect.minY)
    if hasContents { path.addPath(WorkspaceFolderSheet().path(in: rect)) }
    return path
  }
}

/// Only the exposed part needs pixels. Its raised right corner belongs to the
/// silhouette too, so neither native clipping nor the cached shadow cuts it off.
struct WorkspaceFolderSheet: Shape {
  func path(in rect: CGRect) -> Path {
    let sheet = CGRect(x: 0, y: 0, width: rect.width * 0.88, height: rect.height * 0.12)
    let transform = CGAffineTransform(rotationAngle: -.pi / 36)
      .concatenating(.init(translationX: rect.minX + rect.width * 0.055,
        y: rect.minY + rect.height * 0.105))
    return RoundedRectangle(cornerRadius: rect.width * 0.005).path(in: sheet).applying(transform)
  }
}

struct WorkspaceFolderPaint: View {
  let material: WorkspaceCoverMaterial
  let geometry: WorkspaceItemGeometry
  let hasContents: Bool

  var body: some View {
    let outline = WorkspaceCoverOutline(kind: .board, cornerRadius: geometry.cornerRadius)
    let top = geometry.height * (hasContents ? 0.14 : 0.10)
    let face = RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
    ZStack(alignment: .topLeading) {
      outline.fill(material.color)
      outline.fill(LinearGradient(colors: [.white.opacity(0.13), .black.opacity(0.035)],
        startPoint: .topLeading, endPoint: .bottomTrailing))
      outline.stroke(LinearGradient(colors: [.white.opacity(0.6), .black.opacity(0.10)],
        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
      if hasContents {
        WorkspaceFolderSheet()
          .fill(Color(red: 0.965, green: 0.96, blue: 0.93))
          .shadow(color: .black.opacity(0.16), radius: 5, x: 0, y: 3)
          .overlay { WorkspaceFolderSheet().stroke(material.palette.ink.opacity(0.24), lineWidth: 1.5) }
      }
      ZStack {
        face.fill(material.color)
        face.fill(LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.035)],
          startPoint: .topLeading, endPoint: .bottomTrailing))
        face.fill(ImagePaint(image: CoverPaperGrain.image, scale: 1)).opacity(0.12)
        face.strokeBorder(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.12), .black.opacity(0.16)],
          startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
      }
      .frame(width: geometry.width, height: geometry.height - top)
      .offset(y: top)
    }
    .frame(width: geometry.width, height: geometry.height)
    .clipShape(WorkspaceCoverOutline(kind: .board, cornerRadius: geometry.cornerRadius, hasContents: hasContents))
    .accessibilityHidden(true)
  }
}
