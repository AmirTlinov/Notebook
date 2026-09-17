import NotebookCore
import PencilKit
import SwiftUI

/// The same measured-width triangles as raw ink, clipped in the element's
/// local coordinates. Inverse alpha unions overlaps; repeated passes cannot
/// XOR a hole back into existence. No raster is written into the document.
enum NotebookElementErasurePaint {
  static func clip(_ erasures: [InkElementErasure], context: inout GraphicsContext, size: CGSize) {
    guard !erasures.isEmpty else { return }
    context.clipToLayer(options: .inverse) { mask in
      for erasure in erasures {
        var local = mask
        local.scaleBy(x: size.width / erasure.target.frame.width, y: size.height / erasure.target.frame.height)
        let points = erasure.samples.map { sample in
          let p = erasure.target.localPoint(sample)
          return PKStrokePoint(location: .init(x: p.x, y: p.y), timeOffset: sample.timeOffset,
            size: .init(width: sample.width, height: sample.width), opacity: 1,
            force: sample.force, azimuth: sample.azimuth, altitude: sample.altitude)
        }
        var vertices: [SpatialInkGeometry.Vertex] = []
        SpatialInkGeometry.appendStrokeVertices(points: points, color: .init(repeating: 1), to: &vertices)
        // Draw each triangle with positive winding, matching opaque eraser
        // blending even at self intersections and sharp turns.
        var path = Path()
        for i in stride(from: 0, to: vertices.count, by: 3) {
          let a = vertices[i].position, b = vertices[i+1].position, c = vertices[i+2].position
          let positive = (b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x) >= 0
          path.move(to: .init(x: Double(a.x), y: Double(a.y)))
          for p in positive ? [b,c] : [c,b] { path.addLine(to: .init(x: Double(p.x), y: Double(p.y))) }
          path.closeSubpath()
        }
        local.fill(path, with: .color(.white))
      }
    }
  }
}

extension View {
  @ViewBuilder func erased(by erasures: [InkElementErasure]) -> some View {
    if erasures.isEmpty { self }
    else {
      mask {
        Canvas { context, size in
          NotebookElementErasurePaint.clip(erasures, context: &context, size: size)
          context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
        }
      }
    }
  }
}
