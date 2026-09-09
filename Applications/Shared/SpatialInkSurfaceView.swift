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
    private struct PreparedSource {
      let mesh: SpatialInkMesh?
      let journal: SpatialInkJournal?
    }
    private var deferredLayers: [SurfaceID: PreparedSource] = [:]

    func register(_ view: InkCanvasView, for surface: SurfaceID) {
      canvases = canvases.filter { $0.value.view != nil }
      canvases[surface] = WeakCanvas(view)
      if !activeSurfaces.contains(surface),
        let layers = deferredLayers.removeValue(forKey: surface)
      {
        install(layers, on: surface, in: view)
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

    func installedSource(on surface: SurfaceID) -> SpatialInkInstalledSource? {
      guard !activeSurfaces.contains(surface), let source = canvas(for: surface)?.installedSpatialSource,
        source.surface == surface else { return nil }
      return source
    }

    func installedSources() -> [SurfaceID: SpatialInkInstalledSource] {
      var result: [SurfaceID: SpatialInkInstalledSource] = [:]
      for surface in Array(canvases.keys) {
        if let source = installedSource(on: surface) { result[surface] = source }
      }
      return result
    }

    func beginAction(on surface: SurfaceID) {
      if activeSurfaces.insert(surface).inserted { canvas(for: surface)?.beginSpatialAction() }
    }

    func finishAction(on surface: SurfaceID, keepingCommittedMesh: Bool, committedAction: SpatialInkAction? = nil) {
      activeSurfaces.remove(surface)
      canvas(for: surface)?.finishSpatialAction(keepingCommittedMesh: keepingCommittedMesh)
      if keepingCommittedMesh {
        if let committedAction { canvas(for: surface)?.appendInstalledSpatialAction(committedAction) }
        deferredLayers.removeValue(forKey: surface)
        return
      }
      guard let layers = deferredLayers.removeValue(forKey: surface),
        let view = canvas(for: surface)
      else { return }
      install(layers, on: surface, in: view)
    }

    func applyStable(
      _ layers: SpatialInkMesh?,
      source: SpatialInkJournal?,
      to surface: SurfaceID,
      in view: InkCanvasView? = nil
    ) {
      if activeSurfaces.contains(surface) {
        deferredLayers[surface] = .init(mesh: layers, journal: source)
        return
      }
      if let view = view ?? canvas(for: surface) { install(.init(mesh: layers, journal: source), on: surface, in: view) }
    }

    private func install(_ prepared: PreparedSource, on surface: SurfaceID, in view: InkCanvasView) {
      if let mesh = prepared.mesh { view.applySpatial(mesh) } else { view.finishSpatialPreparation() }
      view.installSpatialSource(prepared.journal, on: surface)
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
    private let preparation = SpatialInkMeshPreparation()

    func update(
      view: InkCanvasView,
      surface: SurfaceID,
      journal: SpatialInkJournal?,
      registry: SpatialInkSurfaceRegistry
    ) {
      if self.surface != surface {
        unregister(view)
        self.surface = surface
      }
      if self.registry !== registry {
        self.registry?.unregister(view, for: surface)
        self.registry = registry
      }
      registry.register(view, for: surface)
      let pending = preparation.update(surface: surface, journal: journal) { [weak self, weak view] mesh, source in
        guard let self, self.surface == surface, let registry = self.registry, let view else { return }
        registry.applyStable(mesh, source: source, to: surface, in: view)
      }
      if pending { view.prepareForDrawing() }
    }

    func unregister(_ view: InkCanvasView) {
      guard let surface else { return }
      registry?.unregister(view, for: surface)
      self.surface = nil
      registry = nil
      preparation.cancel()
    }
  }
}
#elseif os(macOS)
struct SpatialInkSurfaceView: NSViewRepresentable {
  let surface: SurfaceID
  let journal: SpatialInkJournal?
  var camera: SpatialCamera? = nil
  var viewport: SpatialPoint? = nil

  func makeCoordinator() -> SpatialInkMeshPreparation { SpatialInkMeshPreparation() }
  func makeNSView(context: Context) -> InkCanvasView { InkCanvasView(frame: .zero) }
  func updateNSView(_ view: InkCanvasView, context: Context) {
    view.project(camera: camera, viewport: viewport ?? .init(x: view.bounds.width, y: view.bounds.height))
    let pending = context.coordinator.update(surface: surface, journal: journal) { [weak view] mesh, source in
      if let mesh { view?.applySpatial(mesh) } else { view?.finishSpatialPreparation() }
      view?.installSpatialSource(source, on: surface)
    }
    if pending { view.prepareForDrawing() }
  }
  static func dismantleNSView(_ view: InkCanvasView, coordinator: SpatialInkMeshPreparation) { coordinator.cancel() }
}

#endif
