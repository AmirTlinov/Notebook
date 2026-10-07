import Foundation
import NotebookCore
import Observation

/// The device's reading intent outlives page hosts. A bookmark is applied only
/// after its measured page lands; a newer contact keeps its own camera.
@MainActor @Observable
final class DocumentReadingSession {
  enum RestorationEffect { case page(Int), camera(SpatialCamera) }

  struct CameraIntent {
    let camera: SpatialCamera
    let fittedScale: Double

    init(camera: SpatialCamera, geometry: WorkspaceItemGeometry, viewport: SpatialPoint) {
      self.camera = camera
      fittedScale = geometry.fitScale(viewport: viewport)
    }
  }

  private struct Measurement {
    let documentID: UUID
    let stamp: VersionStamp
    let layout: DocumentLayoutRecord
  }
  private struct LandingTarget {
    let stamp: VersionStamp
    let page: Int
    let camera: SpatialCamera
    let viewport: SpatialPoint
    let contact: UInt64
  }
  private struct Restoration {
    let documentID: UUID
    var bookmark: DocumentReadingPosition?
    var target: LandingTarget?
  }

  private var positions: [UUID: DocumentReadingPosition] = [:]
  @ObservationIgnored private var measurement: Measurement?
  @ObservationIgnored private var restoration: Restoration?
  @ObservationIgnored private var suppressedDocument: UUID?

  func position(for documentID: UUID) -> DocumentReadingPosition? { positions[documentID] }
  func isRestoring(_ documentID: UUID) -> Bool { restoration?.documentID == documentID }

  func admit(_ position: DocumentReadingPosition?) {
    guard let position, positions[position.documentID] == nil else { return }
    positions[position.documentID] = position
  }

  func layout(for document: DocumentDocument) -> DocumentLayoutRecord? {
    if let measurement, measurement.documentID == document.id, measurement.stamp == document.contentStamp {
      return measurement.layout
    }
    return DocumentRenderRegistry.shared.layout(document: document)
  }

  func openingPage(for document: DocumentDocument, fallback: Int) -> Int {
    guard let saved = positions[document.id], let layout = layout(for: document) else { return fallback }
    return layout.reading.page(for: saved.anchor,
      survivingFileOrder: layout.readingFileOrder, regions: layout.regions) ?? fallback
  }

  func camera(for documentID: UUID, geometry: WorkspaceItemGeometry,
    center: WorldPoint, viewport: SpatialPoint) -> SpatialCamera {
    let fit = geometry.fitScale(viewport: viewport)
    guard let saved = positions[documentID],
      let position = center.addressOffset(x: saved.centerOffset.x, y: saved.centerOffset.y) else {
      return .init(center: center, scale: fit)
    }
    return geometry.readingCamera(.init(center: position, scale: fit * saved.zoomRatio),
      centeredOn: center, viewport: viewport)
  }

  /// A closed cover can start approaching before its PDF has been measured.
  /// Its provisional fit is a reading intent, not an absolute paper scale.
  func openingCamera(_ intent: CameraIntent, document: DocumentDocument, page: Int,
    center: WorldPoint, viewport: SpatialPoint) -> SpatialCamera? {
    guard let layout = layout(for: document) else { return nil }
    let geometry = layout.paper(on: page).geometry
    if isRestoring(document.id), let saved = restoration?.bookmark ?? positions[document.id],
      layout.reading.page(for: saved.anchor, survivingFileOrder: layout.readingFileOrder,
        regions: layout.regions) == page,
      let cameraCenter = center.addressOffset(x: saved.centerOffset.x, y: saved.centerOffset.y) {
      return geometry.readingCamera(.init(center: cameraCenter,
        scale: geometry.fitScale(viewport: viewport) * saved.zoomRatio), centeredOn: center, viewport: viewport)
    }
    let camera = SpatialCamera(center: intent.camera.center,
      scale: geometry.fitScale(viewport: viewport) * intent.camera.scale / intent.fittedScale)
    return geometry.readingCamera(camera, centeredOn: center, viewport: viewport)
  }

  func beginOpening(_ documentID: UUID, restoresReading: Bool) {
    let bookmark = restoration?.documentID == documentID ? restoration?.bookmark : nil
    restoration = restoresReading ? .init(documentID: documentID, bookmark: bookmark) : nil
    suppressedDocument = restoresReading ? nil : documentID
  }

  func beginContact(_ documentID: UUID) {
    restoration = nil
    suppressedDocument = documentID
  }

  /// The accepted pose can replace the bookmark after cancellation. A native
  /// operation may still land, but that receipt cannot revive this intent.
  func cancelRestoration() {
    guard let documentID = restoration?.documentID else { return }
    beginContact(documentID)
  }

  func returnTo(_ position: DocumentReadingPosition) {
    restoration = .init(documentID: position.documentID, bookmark: position)
    suppressedDocument = nil
  }

  func ownerChanged(to presence: SessionPresence, settled: Bool) {
    let preparesMeasurement = measurement.map {
      restoration?.documentID == $0.documentID || suppressedDocument == $0.documentID
    } == true
    if (measurement?.documentID != presence.focusedItemID && !preparesMeasurement)
      || (settled && presence.openProgress <= 0) {
      measurement = nil
    }
    restoration?.target = nil
  }

  func validate(_ documents: [UUID: DocumentDocument]) {
    if let restoration, let target = restoration.target,
      documents[restoration.documentID]?.contentStamp != target.stamp {
      self.restoration?.target = nil
    }
  }

  func accept(_ layout: DocumentPageLayout, document: DocumentDocument,
    presence: SessionPresence?, preparingPage: Int? = nil) -> WorkspaceItemGeometry? {
    let isVisible = presence?.focusedItemID == document.id && (presence?.openProgress ?? 0) > 0
    guard let record = layout.record,
      layout.pageCount(for: DocumentPageNavigation.sourceRevision(document)) != nil,
      isVisible || (preparingPage != nil && presence?.selectedItemID == document.id) else { return nil }
    measurement = .init(documentID: document.id, stamp: document.contentStamp, layout: record)
    return record.paper(on: isVisible ? presence?.documentPageIndex ?? 0 : preparingPage ?? 0).geometry
  }

  func restore(document: DocumentDocument, presence: SessionPresence, center: WorldPoint?,
    settled: Bool, inputIsActive: Bool, selectionPending: Bool, contact: UInt64) -> RestorationEffect? {
    let id = document.id
    guard presence.mode == .document, presence.focusedItemID == id, presence.openProgress >= 0.999,
      settled, !inputIsActive, restoration?.target == nil, suppressedDocument != id, !selectionPending,
      let measurement, measurement.documentID == id, measurement.stamp == document.contentStamp else { return nil }
    guard let saved = restoration?.bookmark ?? positions[id] else { restoration = nil; return nil }
    let layout = measurement.layout
    guard saved.documentID == id,
      restoration?.documentID == id || saved.sourceStamp != document.contentStamp,
      let page = layout.reading.page(for: saved.anchor,
        survivingFileOrder: layout.readingFileOrder, regions: layout.regions) else { return nil }
    if page != presence.documentPageIndex {
      restoration = .init(documentID: id, bookmark: restoration?.bookmark,
        target: .init(stamp: document.contentStamp, page: page, camera: presence.camera,
          viewport: presence.viewport, contact: contact))
      return .page(page)
    }
    restoration = nil
    guard let center, let cameraCenter = center.addressOffset(x: saved.centerOffset.x, y: saved.centerOffset.y) else { return nil }
    let camera = SpatialCamera(center: cameraCenter, scale: max(SpatialCamera.minimumScale,
      layout.paper(on: page).geometry.fitScale(viewport: presence.viewport) * saved.zoomRatio))
    return camera == presence.camera ? nil : .camera(camera)
  }

  func landed(_ landing: DocumentPageLanding, document: DocumentDocument,
    presence: SessionPresence, contact: UInt64) {
    guard let restoration, restoration.documentID == landing.documentID,
      let target = restoration.target, target.page == landing.pageIndex,
      document.contentStamp == target.stamp else { return }
    self.restoration?.target = nil
    if target.camera != presence.camera || target.viewport != presence.viewport || target.contact != contact {
      beginContact(landing.documentID)
    }
  }

  /// Returns only a changed bookmark; the common writer owns its persistence.
  func remember(document: DocumentDocument, presence: SessionPresence, center: WorldPoint?,
    selectionPending: Bool, retaining documentIDs: @autoclosure () -> Set<UUID>) -> DocumentReadingPosition? {
    let id = document.id
    guard presence.mode == .document, presence.focusedItemID == id, presence.openProgress >= 0.999,
      !isRestoring(id), !selectionPending, let measurement,
      measurement.documentID == id, measurement.stamp == document.contentStamp, let center else { return nil }
    let layout = measurement.layout
    let geometry = layout.paper(on: presence.documentPageIndex).geometry
    let offset = center.delta(to: presence.camera.center)
    let visibleTop = max(0, geometry.height / 2 + offset.y - presence.viewport.y / (2 * presence.camera.scale))
    let order = layout.readingFileOrder
    let anchor = layout.reading.anchor(page: presence.documentPageIndex, fileOrder: order, y: visibleTop)
      ?? layout.regions.first(where: {
        $0.kind == .file && $0.pageIndex == presence.documentPageIndex && order.contains($0.id)
      }).map { DocumentReadingAnchor(fileID: $0.id, nodeID: "", textOffset: 0, offset: 0, fileOrder: order) }
    guard let anchor else { return nil }
    let position = DocumentReadingPosition(documentID: id, sourceStamp: document.contentStamp, anchor: anchor,
      zoomRatio: presence.camera.scale / geometry.fitScale(viewport: presence.viewport), centerOffset: offset)
    guard position.isValid else { return nil }
    if suppressedDocument == id { suppressedDocument = nil }
    guard positions[id] != position else { return nil }
    positions[id] = position
    if positions.count > 32 {
      let retained = documentIDs()
      positions = positions.filter { $0.key == id || retained.contains($0.key) }
    }
    return position
  }
}
