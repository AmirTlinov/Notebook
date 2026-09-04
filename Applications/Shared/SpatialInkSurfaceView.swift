import PencilKit
import SwiftUI
import NotebookCore

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Connects the window-level Pencil recognizer to the Metal canvas carried by
/// each physical surface. The registry routes samples; it never draws them.
@MainActor
final class SpatialInkSurfaceRegistry {
  #if os(iOS)
    private final class WeakCanvas {
      weak var view: InkCanvasView?

      init(_ view: InkCanvasView) {
        self.view = view
      }
    }

    private var canvases: [SurfaceID: WeakCanvas] = [:]
    private var activeSurfaces: Set<SurfaceID> = []
    private var deferredLayers: [SurfaceID: [SpatialInkRenderLayer]] = [:]

    func register(_ view: InkCanvasView, for surface: SurfaceID) {
      canvases = canvases.filter { $0.value.view != nil }
      canvases[surface] = WeakCanvas(view)
      if !activeSurfaces.contains(surface),
        let layers = deferredLayers.removeValue(forKey: surface)
      {
        view.applySpatial(layers)
      }
    }

    func unregister(_ view: InkCanvasView, for surface: SurfaceID) {
      guard canvases[surface]?.view === view else { return }
      canvases.removeValue(forKey: surface)
    }

    func canvas(for surface: SurfaceID) -> InkCanvasView? {
      guard let view = canvases[surface]?.view else {
        canvases.removeValue(forKey: surface)
        return nil
      }
      return view
    }

    func beginAction(on surface: SurfaceID) {
      activeSurfaces.insert(surface)
    }

    func finishAction(on surface: SurfaceID, keepingCommittedMesh: Bool) {
      activeSurfaces.remove(surface)
      if keepingCommittedMesh {
        deferredLayers.removeValue(forKey: surface)
        return
      }
      guard let layers = deferredLayers.removeValue(forKey: surface),
        let view = canvas(for: surface)
      else { return }
      view.applySpatial(layers)
    }

    func applyStable(
      _ layers: [SpatialInkRenderLayer],
      to surface: SurfaceID,
      in view: InkCanvasView? = nil
    ) {
      if activeSurfaces.contains(surface) {
        deferredLayers[surface] = layers
        return
      }
      (view ?? canvas(for: surface))?.applySpatial(layers)
    }
  #endif
}

/// Builds the PencilKit representation used by Mac previews and persistence.
/// The iPad replays the journal's raw samples in each physical surface owner.
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
    board: SurfaceID,
    in journal: SpatialInkJournal?,
    camera: SpatialCamera,
    viewport: SpatialPoint
  ) -> PKDrawing {
    compose(surface: board, journal: journal) { sample in
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
/// The permanent Metal canvas carried by one physical cover. SwiftUI moves,
/// scales, and opens this view together with the cover, so its ink cannot lag
/// behind or slip below the notebook.
struct SpatialInkSurfaceView: UIViewRepresentable {
  let surface: SurfaceID
  let journal: SpatialInkJournal?
  let registry: SpatialInkSurfaceRegistry

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> InkCanvasView {
    let view = InkCanvasView(frame: .zero)
    context.coordinator.update(
      view: view,
      surface: surface,
      journal: journal,
      registry: registry
    )
    return view
  }

  func updateUIView(_ view: InkCanvasView, context: Context) {
    context.coordinator.update(
      view: view,
      surface: surface,
      journal: journal,
      registry: registry
    )
  }

  static func dismantleUIView(
    _ view: InkCanvasView,
    coordinator: Coordinator
  ) {
    coordinator.unregister(view)
  }

  @MainActor
  final class Coordinator {
    private weak var registry: SpatialInkSurfaceRegistry?
    private var surface: SurfaceID?
    private var appliedStamp: VersionStamp?

    func update(
      view: InkCanvasView,
      surface: SurfaceID,
      journal: SpatialInkJournal?,
      registry: SpatialInkSurfaceRegistry
    ) {
      if self.registry !== registry || self.surface != surface {
        unregister(view)
        self.registry = registry
        self.surface = surface
        registry.register(view, for: surface)
        appliedStamp = nil
      }
      guard appliedStamp != journal?.stamp else { return }
      appliedStamp = journal?.stamp
      registry.applyStable(
        SpatialInkComposer.localLayers(for: surface, journal: journal),
        to: surface,
        in: view
      )
    }

    func unregister(_ view: InkCanvasView) {
      guard let surface else { return }
      registry?.unregister(view, for: surface)
      self.surface = nil
      registry = nil
      appliedStamp = nil
    }
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
