import CoreGraphics
import CryptoKit
import Foundation
import NotebookCore

/// Completed local pixels share the composition pool. Their identity follows
/// paint inputs; world placement and unrelated owner revisions stay outside it.
struct SceneMaterialKey: Hashable, Codable, Sendable {
  let workspaceID: UUID
  let fingerprint: String

  init(workspaceID: UUID, target: CollaborationTarget, revision: String, role: String, frame: PageRect, density: Double) throws {
    self.workspaceID = workspaceID
    let value = JSONValue.object(["target": try .encode(target), "revision": .string(revision),
      "role": .string(role), "frame": try .encode(frame), "density": .number(density)])
    fingerprint = try Self.digest(value)
  }

  init(workspaceID: UUID, boardID: UUID, paint: SceneCompositionSource.ElementPaint,
    presentation: NotebookElementPresentation?, density: Double) throws {
    self.workspaceID = workspaceID
    fingerprint = try Self.digest(ElementPixels(boardID: boardID, paint: paint,
      presentation: presentation, density: density))
  }

  private static func digest(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
  }

  private struct ElementPixels: Encodable {
    struct Text: Encodable { let source: String; let style: NativeTextStyle }
    let boardID: UUID
    let kind: SpatialElementKind
    let source: AgentElement?
    let text: Text?
    let graphic: NotebookGraphic?
    let bodySize: CGSize?
    let transform: NotebookGraphicTransform?
    let layout: GraphicPixels?
    let erasures: [InkElementErasure]
    let density: Double

    init(boardID: UUID, paint: SceneCompositionSource.ElementPaint,
      presentation: NotebookElementPresentation?, density: Double) {
      self.boardID = boardID; kind = paint.element.kind
      // Native paint never reads the program payload. Keeping those fields out
      // also avoids encoding hidden HTML/state beside a measured ink body.
      source = kind == .nativeText || paint.element.graphic != nil
        ? nil : agentElementSnapshotSource(paint.element)
      text = kind == .nativeText ? .init(source: paint.element.source, style: paint.element.textStyle) : nil
      graphic = paint.element.graphic
      bodySize = presentation?.bodySize
      transform = presentation.map { Self.localTransform($0.transform) }
      layout = paint.layout.map(GraphicPixels.init)
      erasures = paint.erasures; self.density = density
    }

    static func localTransform(_ value: CGAffineTransform) -> NotebookGraphicTransform {
      .init(a: value.a, b: value.b, c: value.c, d: value.d, tx: value.tx, ty: value.ty)
    }
  }

  /// Resolved connector geometry may change when another element moves, even
  /// while this element's authored content and causal stamp remain unchanged.
  private struct GraphicPixels: Encodable {
    struct Head: Encodable { let points: [SpatialPoint]; let filled: Bool; let closed: Bool }
    let size: CGSize
    let projectionSize: CGSize?
    let projection: NotebookGraphicTransform?
    let curves: [[SpatialPoint]]
    let heads: [Head]
    let label: SpatialPoint

    init(_ layout: NotebookGraphicLayout) {
      size = .init(width: layout.frame.width, height: layout.frame.height)
      projectionSize = layout.projection?.size
      projection = layout.projection.map { ElementPixels.localTransform($0.transform) }
      curves = layout.curves.map { [$0.start, $0.control1, $0.control2, $0.end] }
      heads = layout.heads.map { .init(points: $0.points, filled: $0.filled, closed: $0.closed) }
      label = layout.label
    }
  }
}
