import Foundation
import NotebookCore
import Observation

/// Unsent pointing is short-lived device state, never durable chat attachments
/// or the workspace's shared selection. Sending drains exactly one batch.
@MainActor @Observable
final class NotebookLaserContext {
  struct Scope: Equatable { let computer: UUID?; let thread: String }
  typealias Render = @MainActor () async throws -> [NotebookChatImage]
  private struct Entry { let time: TimeInterval; let scope: Scope; let render: Render }
  private var entries: [Entry] = []
  @ObservationIgnored private var expiry: Task<Void,Never>?
  @ObservationIgnored private let now: () -> TimeInterval
  var count: Int { entries.count }
  func count(scope: Scope) -> Int { entries.filter { $0.scope == scope && now()-$0.time < 30 }.count }
  init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
  func append(scope: Scope, render: @escaping Render) {
    prune()
    entries.append(.init(time:now(),scope:scope,render:render))
    if entries.count > 5 { entries.removeFirst(entries.count-5) }
    scheduleExpiry()
  }
  func take(scope: Scope) -> [Render] {
    prune()
    let result = entries.filter { $0.scope == scope }.map(\.render)
    clear()
    return result
  }
  func clear() { entries = []; expiry?.cancel(); expiry = nil }
  func prune() { entries.removeAll { now()-$0.time >= 30 } }
  static func images(_ batch: [Render]) async -> [NotebookChatImage] {
    var result: [NotebookChatImage] = [], bytes = 0
    for render in batch {
      guard let images = try? await render() else { continue }
      for value in images where result.count < 5 {
        guard value.image.png.count <= 4*1024*1024-bytes else { continue }
        result.append(value); bytes += value.image.png.count
      }
    }
    return result
  }
  private func scheduleExpiry() {
    expiry?.cancel()
    guard let first = entries.first else { expiry = nil; return }
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
    guard let chat, let thread = chat.threadID, let presence, let cohort = compositionTiles.published,
      let first = contact.points.first else { return }
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
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for point in contact.points {
      minX = min(minX,point.x); maxX = max(maxX,point.x)
      minY = min(minY,point.y); maxY = max(maxY,point.y)
    }
    let box = CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY).insetBy(dx:-24/scale,dy:-24/scale)
    let start = CGPoint(x:origin.x+box.minX*scale,y:origin.y+box.minY*scale)
    let end = CGPoint(x:origin.x+box.maxX*scale,y:origin.y+box.maxY*scale)
    guard let capture = NotebookAttentionProjection.capture(start:start,end:end,model:self,presence:presence,
      cohort:cohort,installedInk:compositionTiles.surfaceRegistry.installedSources())?.freezingSubmissionVisuals() else { return }
    laserContext.append(scope:.init(computer:chat.computerID,thread:thread)) {
      let ready = try await capture.resolvingAcceptedElements()
      let references = try await Task.detached { try ready.resolvedReferences() }.value
      let images = try await ready.renderPinnedImages(references:references)
      return references.prefix(5).compactMap { reference in
        guard let image = images.images[reference.id] else { return nil }
        return .init(reference:reference,image:image)
      }
    }
  }
}
#endif
