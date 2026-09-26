import Foundation
import NotebookCore
import Observation

/// One frozen pointing batch belongs to the submitted draft or native task.
/// Failed preparation keeps that batch available; only durable Send consumes it.
@MainActor @Observable
final class NotebookLaserContext {
  struct Scope: Equatable { let computer: UUID?; let thread: String }
  typealias Render = @MainActor () async throws -> [NotebookChatImage]
  fileprivate struct Entry { let id = UUID(); var time: TimeInterval; var scope: Scope; let render: Render }
  struct Batch {
    fileprivate let entries: [Entry]
    let intentGeneration: UInt64
    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
  }
  private(set) var intentGeneration: UInt64 = 0
  private var entries: [Entry] = []
  private var reserved = Set<UUID>()
  @ObservationIgnored private var expiry: Task<Void,Never>?
  @ObservationIgnored private let now: () -> TimeInterval
  var count: Int { entries.count }
  func count(scope: Scope) -> Int { entries.filter { $0.scope == scope && (reserved.contains($0.id) || now()-$0.time < 30) }.count }
  init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
  func append(scope: Scope, render: @escaping Render) {
    intentGeneration &+= 1
    prune()
    entries.append(.init(time:now(),scope:scope,render:render))
    let excess = entries.filter { !reserved.contains($0.id) }.dropLast(5).map(\.id)
    entries.removeAll { excess.contains($0.id) }
    scheduleExpiry()
  }
  func snapshot(scope: Scope) -> Batch {
    prune()
    return .init(entries: entries.filter { $0.scope == scope && !reserved.contains($0.id) }, intentGeneration:intentGeneration)
  }
  func reserve(_ batch: Batch) {
    for entry in batch.entries {
      reserved.insert(entry.id)
      if !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
    }
    scheduleExpiry()
  }
  func rebind(_ batch: Batch, to scope: Scope) {
    let ids = Set(batch.entries.map(\.id))
    for index in entries.indices where ids.contains(entries[index].id) { entries[index].scope = scope }
  }
  func finish(_ batch: Batch, consumed: Bool) {
    let ids = Set(batch.entries.map(\.id))
    if consumed { entries.removeAll { ids.contains($0.id) } }
    else {
      for index in entries.indices where ids.contains(entries[index].id) { entries[index].time = now() }
    }
    reserved.subtract(ids); scheduleExpiry()
  }
  func clear() { intentGeneration &+= 1; entries = []; expiry?.cancel(); expiry = nil }
  func prune() { entries.removeAll { !reserved.contains($0.id) && now()-$0.time >= 30 } }
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
  private func scheduleExpiry() {
    expiry?.cancel()
    guard let first = entries.filter({ !reserved.contains($0.id) }).min(by: { $0.time < $1.time }) else { expiry = nil; return }
    let delay = max(0,30-(now()-first.time))
    expiry = Task { [weak self] in
      do { try await Task.sleep(for:.seconds(delay)) } catch { return }
      guard let self else { return }
      prune(); scheduleExpiry()
    }
  }
}

#if os(iOS)
extension NotebookAppModel {
  func captureLaserContext(_ contact: NotebookDrawingToolController.Contact) {
    guard let chat, let presence, let cohort = compositionTiles.published,
      !contact.points.isEmpty else { return }
    let origin: CGPoint
    if contact.address.surface.kind == .board {
      guard contact.address.boardID == presence.boardID else { return }
      let value = presence.camera.worldToScreen(contact.address.worldOrigin ?? .zero,viewport:presence.viewport)
      origin = .init(x:value.x,y:value.y)
    } else {
      guard let rect = NotebookAttentionProjection.frame(.init(target:contact.address.target,revision:""),model:self,presence:presence) else { return }
      origin = rect.origin
    }
    let scale = presence.camera.scale
    let box = contact.contour.bounds.insetBy(dx:-24/scale,dy:-24/scale)
    let start = CGPoint(x:origin.x+box.minX*scale,y:origin.y+box.minY*scale)
    let end = CGPoint(x:origin.x+box.maxX*scale,y:origin.y+box.maxY*scale)
    guard let capture = NotebookAttentionProjection.capture(start:start,end:end,model:self,presence:presence,
      cohort:cohort,installedInk:compositionTiles.surfaceRegistry.installedSources(), compositeRegion: true)?.freezingSubmissionVisuals() else {
      laserContext.append(scope:chat.pointingScope) { throw CollaborationError("pointing_not_ready", "Изображение указки ещё не готово. Укажите фрагмент после завершения движения.") }; return
    }
    laserContext.append(scope:chat.pointingScope) {
      let ready = try await capture.resolvingAcceptedCommands()
      let references = try await Task.detached { try ready.resolvedReferences() }.value
      let images = try await ready.renderPinnedImages(references:references)
      return try references.map { reference in
        guard let image = images.images[reference.id] else { throw CollaborationError("pointing_pixels_missing", images.unavailable[reference.id] ?? "Изображение указки недоступно. Укажите фрагмент снова.") }
        return .init(reference:reference,image:image)
      }
    }
  }
}
#endif
