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
  let surface: SurfaceID
  let journal: SpatialInkJournal?
  var camera: SpatialCamera? = nil
  var viewport: SpatialPoint? = nil

  var body: some View {
    GeometryReader { geometry in
      if let image = SpatialInkRasterCache.shared.image(surface: surface, journal: journal,
        camera: camera, viewport: viewport, size: geometry.size) {
        Image(nsImage: image).resizable()
      }
    }
  }
}
#endif
