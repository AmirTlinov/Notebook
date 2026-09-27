import Foundation
import CryptoKit
import NotebookCore
import Observation
import SwiftUI

/// One frozen pointing batch belongs to the submitted draft or native task.
/// Failed preparation keeps that batch available; only durable Send consumes it.
@MainActor @Observable
final class NotebookLaserContext {
  struct Scope: Equatable, Sendable { let computer: UUID?; let thread: String }
  typealias Render = @MainActor () async throws -> [NotebookChatImage]
  fileprivate struct Entry { let id = UUID(); var scope: Scope; let render: Render }
  struct Batch {
    fileprivate let entries: [Entry]
    let intentGeneration: UInt64
    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
  }
  private(set) var intentGeneration: UInt64 = 0
  private var entries: [Entry] = []
  private var reserved = Set<UUID>()
  var count: Int { entries.count }
  func count(scope: Scope) -> Int { entries.filter { $0.scope == scope }.count }
  func append(scope: Scope, render: @escaping Render) {
    if entries.last.map({ $0.scope != scope }) == true { clear() }
    intentGeneration &+= 1
    entries.append(.init(scope:scope,render:render))
    let excess = entries.filter { !reserved.contains($0.id) }.dropLast(5).map(\.id)
    entries.removeAll { excess.contains($0.id) }
  }
  func snapshot(scope: Scope) -> Batch {
    return .init(entries: entries.filter { $0.scope == scope && !reserved.contains($0.id) }, intentGeneration:intentGeneration)
  }
  func reserve(_ batch: Batch) {
    for entry in batch.entries {
      reserved.insert(entry.id)
      if !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
    }
  }
  func rebind(_ batch: Batch, to scope: Scope) {
    let ids = Set(batch.entries.map(\.id))
    for index in entries.indices where ids.contains(entries[index].id) { entries[index].scope = scope }
  }
  func finish(_ batch: Batch, consumed: Bool) {
    let ids = Set(batch.entries.map(\.id))
    if consumed { entries.removeAll { ids.contains($0.id) } }
    reserved.subtract(ids)
  }
  func clear() { intentGeneration &+= 1; entries = []; reserved = [] }
  static func images(_ batch: Batch) async throws -> [NotebookChatImage] {
    var result: [NotebookChatImage] = [], bytes = 0
    for entry in batch.entries {
      let images = try await entry.render()
      guard !images.isEmpty else { throw CollaborationError("pointing_pixels_missing", "Не удалось получить изображение указки. Укажите готовый фрагмент ещё раз.") }
      for value in images {
        guard result.count < 5, value.image.png.count <= 4*1024*1024-bytes else {
          throw CollaborationError("pointing_image_limit", "Указано больше пяти изображений или 4 МиБ. Уберите лишние указания перед отправкой.")
        }
        result.append(value); bytes += value.image.png.count
      }
    }
    return result
  }
  /// Coordinates are fixed against the same frame as the frozen source, not
  /// recalculated from the camera or paper when the message is eventually sent.
  struct Outline: Sendable {
    let points: [SpatialPoint]
    let width: Double
    init(points: [SpatialPoint], sourceOrigin: CGPoint, cropOrigin: CGPoint, scale: Double, width: Double) {
      let dx = (sourceOrigin.x-cropOrigin.x)/scale, dy = (sourceOrigin.y-cropOrigin.y)/scale
      self.points = points.map { .init(x:$0.x+dx,y:$0.y+dy) }
      self.width = width
    }
  }

  static func outlining(_ image: AgentPinnedImage, with outline: Outline,
    resources: SceneRenderResources = .shared) async throws -> AgentPinnedImage {
    guard let first = outline.points.first, outline.width.isFinite, outline.width > 0,
      outline.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
      throw SceneRenderError.snapshotPending("laser_contour_unavailable")
    }
    let size = CGSize(width:image.region.width,height:image.region.height), frame = CGRect(origin:.zero,size:size)
    let canvas = try await SceneRasterCompositor.create(size:size,scale:image.pixelsPerPoint,resources:resources)
    try await canvas.drawPNG(image.png,in:frame)
    let red = Color(.sRGB,red:1,green:0,blue:0,opacity:1)
    if outline.points.count == 1 {
      let dot = Path(ellipseIn:.init(x:first.x-outline.width/2,y:first.y-outline.width/2,
        width:outline.width,height:outline.width))
      try await canvas.drawView(dot.fill(red),size:size,in:frame)
    } else {
      let path = Path { path in
        path.move(to:.init(x:first.x,y:first.y))
        for point in outline.points.dropFirst() { path.addLine(to:.init(x:point.x,y:point.y)) }
      }
      try await canvas.drawView(path.stroke(red,style:.init(lineWidth:outline.width,lineCap:.round,lineJoin:.round)),
        size:size,in:frame)
    }
    let png = try await canvas.finishPNG()
    return try await Task.detached(priority:.utility) {
      let hash = SHA256.hash(data:png).map { String(format:"%02x",$0) }.joined()
      // This is annotated context, not an unmodified presentation that could
      // authorize a later export of a paused program or exact screen pixels.
      return try AgentPinnedImage(referenceID:image.referenceID,sourceRevision:image.sourceRevision,
        region:image.region,worldOrigin:image.worldOrigin,pageIndex:image.pageIndex,
        pixelWidth:image.pixelWidth,pixelHeight:image.pixelHeight,pixelsPerPoint:image.pixelsPerPoint,png:png,sha256:hash)
    }.value
  }
}

#if os(iOS)
extension NotebookAppModel {
  func captureLaserContext(_ contact: NotebookDrawingToolController.LaserContact) {
    guard let chat, contact.scope == chat.pointingScope,
      let presence, let cohort = compositionTiles.published,
      !contact.points.isEmpty,
      let frame = NotebookAttentionProjection.laserFrame(contact.address,model:self,presence:presence) else { return }
    let origin = frame.origin, scale = presence.camera.scale
    let box = contact.contour.bounds.insetBy(dx:-24/scale,dy:-24/scale)
    let start = CGPoint(x:origin.x+box.minX*scale,y:origin.y+box.minY*scale)
    let end = CGPoint(x:origin.x+box.maxX*scale,y:origin.y+box.maxY*scale)
    guard let capture = NotebookAttentionProjection.capture(start:start,end:end,model:self,presence:presence,
      cohort:cohort,installedInk:compositionTiles.surfaceRegistry.installedSources(),compositeRegion:true)?.freezingSubmissionVisuals() else {
      laserContext.append(scope:chat.pointingScope) { throw CollaborationError("pointing_not_ready", "Изображение указки ещё не готово. Укажите фрагмент после завершения движения.") }; return
    }
    var outlines: [UUID:NotebookLaserContext.Outline] = [:]
    for fragment in capture.fragments {
      let reference = CollaborationReference(target:fragment.target,region:fragment.region,
        worldOrigin:fragment.worldOrigin,pageIndex:fragment.pageIndex,revision:"")
      guard let frame = NotebookAttentionProjection.frame(reference,model:self,presence:presence) else { continue }
      outlines[fragment.id] = .init(points:contact.points,sourceOrigin:origin,cropOrigin:frame.origin,
        scale:scale,width:4/contact.screenScale)
    }
    laserContext.append(scope:chat.pointingScope) {
      let ready = try await capture.resolvingAcceptedCommands()
      let references = try await Task.detached { try ready.resolvedReferences() }.value
      let images = try await ready.renderPinnedImages(references:references)
      var result: [NotebookChatImage] = []
      for reference in references {
        guard let image = images.images[reference.id], let outline = outlines[reference.id] else {
          throw CollaborationError("pointing_pixels_missing", images.unavailable[reference.id] ?? "Изображение указки недоступно. Укажите фрагмент снова.")
        }
        result.append(.init(reference:reference,image:try await NotebookLaserContext.outlining(image,with:outline)))
      }
      return result
    }
  }
}
#endif
