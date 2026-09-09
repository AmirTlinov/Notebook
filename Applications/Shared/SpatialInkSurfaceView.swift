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
      weak var pose: WorkspaceItemPoseController?

      init(_ view: InkCanvasView? = nil) {
        self.view = view
      }
    }

    private var canvases: [SurfaceID: WeakCanvas] = [:]
    private var retainedCanvases: [SurfaceID: (view: InkCanvasView, count: Int)] = [:]
    private var activeSurfaces: Set<SurfaceID> = []
    private struct PreparedSource {
      let mesh: SpatialInkMesh?
      let journal: SpatialInkJournal?
    }
    private var deferredLayers: [SurfaceID: PreparedSource] = [:]

    func register(_ view: InkCanvasView, for surface: SurfaceID) {
      canvases = canvases.filter { $0.value.view != nil || $0.value.pose != nil }
      let entry = canvases[surface] ?? WeakCanvas()
      entry.view = view; canvases[surface] = entry
      if !activeSurfaces.contains(surface),
        let layers = deferredLayers.removeValue(forKey: surface)
      {
        install(layers, on: surface, in: view)
      }
    }

    func unregister(_ view: InkCanvasView, for surface: SurfaceID) {
      guard canvases[surface]?.view === view else { return }
      canvases[surface]?.view = nil
      if canvases[surface]?.pose == nil { canvases.removeValue(forKey: surface) }
    }

    func canvas(for surface: SurfaceID) -> InkCanvasView? {
      if let retained = retainedCanvases[surface] { return retained.view }
      guard let view = canvases[surface]?.view else {
        if canvases[surface]?.pose == nil { canvases.removeValue(forKey: surface) }
        return nil
      }
      return view
    }

    func registerPose(_ pose: WorkspaceItemPoseController, for surface: SurfaceID) {
      let entry = canvases[surface] ?? WeakCanvas()
      entry.pose = pose; canvases[surface] = entry
    }

    func unregisterPose(_ pose: WorkspaceItemPoseController, for surface: SurfaceID) {
      guard canvases[surface]?.pose === pose else { return }
      canvases[surface]?.pose = nil
      if canvases[surface]?.view == nil { canvases[surface] = nil }
    }

    func pose(for surface: SurfaceID) -> WorkspaceItemPoseController? { canvases[surface]?.pose }

    func retirePhysicalOwner(_ id: UUID, on boardID: UUID, through revision: UInt64) {
      guard let pose = pose(for: .cover(id)), pose.boardID == boardID else { return }
      pose.retirePhysicalOwner(through: revision)
    }

    func isRetired(_ surface: SurfaceID) -> Bool { pose(for: surface)?.retiredAtRevision != nil }

    /// The existing physical registration is retained, not looked up again after
    /// every sample. A late replacement/unregister cannot redirect accepted ink.
    func acquireContact(on surface: SurfaceID, in coordinateView: UIView) -> ContactLease? {
      let pose = canvases[surface]?.pose
      let poseLease = pose?.acquirePose(in: coordinateView)
      if pose != nil && poseLease == nil { return nil }
      let canvas = canvas(for: surface)
      if let canvas {
        let count = retainedCanvases[surface]?.count ?? 0
        retainedCanvases[surface] = (canvas, count + 1)
      }
      return ContactLease(registry: self, surface: surface, canvas: canvas, pose: poseLease)
    }

    private func releaseContact(on surface: SurfaceID, canvas: InkCanvasView?) {
      guard let canvas, let retained = retainedCanvases[surface], retained.view === canvas else { return }
      if retained.count == 1 { retainedCanvases[surface] = nil }
      else { retainedCanvases[surface] = (canvas, retained.count - 1) }
    }

    @MainActor
    final class ContactLease {
      let canvas: InkCanvasView?
      let pose: WorkspaceItemPoseLease?
      private weak var registry: SpatialInkSurfaceRegistry?
      private let surface: SurfaceID
      fileprivate init(registry: SpatialInkSurfaceRegistry, surface: SurfaceID,
        canvas: InkCanvasView?, pose: WorkspaceItemPoseLease?) {
        self.registry = registry; self.surface = surface; self.canvas = canvas; self.pose = pose
      }
      func release() {
        registry?.releaseContact(on: surface, canvas: canvas); registry = nil
        pose?.release()
      }
      isolated deinit { release() }
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
