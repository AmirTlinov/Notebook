import PencilKit
import SwiftUI
import NotebookCore

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Replays one persistent surface into one drawing. The journal owns the ink;
/// the board and each cover only choose where that same ink is presented.
enum SpatialInkDrawingComposer {
  static func drawing(
    for surface: SurfaceID,
    in journal: SpatialInkJournal?
  ) -> PKDrawing {
    compose(surface: surface, journal: journal) { sample in
      pkPoint(sample)
    }
  }

  static func boardDrawing(
    in journal: SpatialInkJournal?,
    camera: SpatialCamera,
    viewport: SpatialPoint
  ) -> PKDrawing {
    compose(surface: .board, journal: journal) { sample in
      guard let worldPoint = sample.worldPoint else { return nil }
      let screen = camera.worldToScreen(worldPoint, viewport: viewport)
      return pkPoint(
        sample,
        location: CGPoint(x: screen.x, y: screen.y),
        widthScale: camera.scale
      )
    }
  }

  private static func compose(
    surface: SurfaceID,
    journal: SpatialInkJournal?,
    point: (SpatialInkSample) -> PKStrokePoint?
  ) -> PKDrawing {
    guard let journal else { return PKDrawing() }
    var drawing = PKDrawing()
    var pendingInk: [PKStroke] = []
    for action in journal.actions where action.isActive {
      for span in action.spans where span.surface == surface {
        let points = span.samples.compactMap(point)
        guard !points.isEmpty else { continue }
        let path = PKStrokePath(
          controlPoints: points,
          creationDate: Date(
            timeIntervalSince1970: Double(action.stamp.counter)
          )
        )
        if action.tool == .pen {
          #if os(iOS)
          let color = UIColor(
            red: action.color.red,
            green: action.color.green,
            blue: action.color.blue,
            alpha: 1
          )
          #else
          let color = NSColor(
            calibratedRed: action.color.red,
            green: action.color.green,
            blue: action.color.blue,
            alpha: 1
          )
          #endif
          pendingInk.append(
            PKStroke(ink: PKInk(.monoline, color: color), path: path)
          )
        } else {
          if !pendingInk.isEmpty {
            drawing = PKDrawing(strokes: drawing.strokes + pendingInk)
            pendingInk.removeAll(keepingCapacity: true)
          }
          drawing = drawing.erasingPath(path)
        }
      }
    }
    guard !pendingInk.isEmpty else { return drawing }
    return PKDrawing(strokes: drawing.strokes + pendingInk)
  }

  private static func pkPoint(
    _ sample: SpatialInkSample,
    location: CGPoint? = nil,
    widthScale: Double = 1
  ) -> PKStrokePoint {
    PKStrokePoint(
      location: location ?? CGPoint(x: sample.point.x, y: sample.point.y),
      timeOffset: sample.timeOffset,
      size: CGSize(
        width: sample.width * widthScale,
        height: sample.width * widthScale
      ),
      opacity: sample.opacity,
      force: sample.force,
      azimuth: sample.azimuth,
      altitude: sample.altitude
    )
  }
}

#if os(iOS)
struct SpatialInkSurfaceView: UIViewRepresentable {
  let drawing: PKDrawing

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> InkCanvasView {
    let view = InkCanvasView(frame: .zero)
    view.apply(drawing)
    context.coordinator.drawing = drawing
    return view
  }

  func updateUIView(_ view: InkCanvasView, context: Context) {
    guard context.coordinator.drawing != drawing else { return }
    context.coordinator.drawing = drawing
    view.apply(drawing)
  }

  @MainActor
  final class Coordinator {
    var drawing = PKDrawing()
  }
}
#elseif os(macOS)
struct SpatialInkSurfaceView: View {
  let drawing: PKDrawing

  var body: some View {
    GeometryReader { geometry in
      if !drawing.strokes.isEmpty {
        Image(
          nsImage: PaperInkRenderer.image(
            from: drawing,
            bounds: CGRect(origin: .zero, size: geometry.size),
            scale: 2
          )
        )
        .resizable()
      }
    }
  }
}
#endif
