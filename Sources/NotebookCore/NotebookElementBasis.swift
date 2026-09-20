import CoreGraphics
import Foundation

/// A whole element's local coordinate system, including its stroke, text layout
/// and children. A group has no second scene or members array: parentID owns
/// membership, while frame/basis owns placement for every content kind.
public struct NotebookElementBasis: Codable, Equatable, Sendable {
  // One immutable payload follows source copies into placements and drafts.
  // An absent basis costs one pointer, not eight reserved Doubles per leaf.
  private final class Value: Sendable {
    let size: SpatialPoint
    let transform: NotebookGraphicTransform?
    init(size: SpatialPoint,transform: NotebookGraphicTransform?) { self.size=size;self.transform=transform }
  }
  private let value: Value
  public var size: SpatialPoint { value.size }
  public var transform: NotebookGraphicTransform? { value.transform }
  public init(size: SpatialPoint, transform: NotebookGraphicTransform? = nil) {
    value=Value(size:size,transform:transform)
  }
  public static func == (a: Self,b: Self) -> Bool {
    a.value === b.value || (a.size == b.size && a.transform == b.transform)
  }
  private enum CodingKeys: String,CodingKey { case size,transform }
  public init(from decoder: Decoder) throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    self.init(size:try c.decode(SpatialPoint.self,forKey:.size),transform:try c.decodeIfPresent(NotebookGraphicTransform.self,forKey:.transform))
  }
  public func encode(to encoder: Encoder) throws {
    var c=encoder.container(keyedBy:CodingKeys.self)
    try c.encode(size,forKey:.size);try c.encodeIfPresent(transform,forKey:.transform)
  }
  var isValid: Bool {
    size.x.isFinite && size.y.isFinite && size.x > 0 && size.y > 0
      && size.x <= 1_000_000 && size.y <= 1_000_000 && (transform?.isValid ?? true)
  }
  /// Local member points -> the parent's coordinates. Multiplication order is
  /// explicit: normalize the local body, apply its basis, then place the frame.
  public func placement(in frame: PageRect) throws -> CGAffineTransform {
    let t = transform ?? .identity
    let result = CGAffineTransform(a:frame.width*t.a/size.x,b:frame.height*t.b/size.x,
      c:frame.width*t.c/size.y,d:frame.height*t.d/size.y,
      tx:frame.x+frame.width*t.tx,ty:frame.y+frame.height*t.ty)
    guard [result.a,result.b,result.c,result.d,result.tx,result.ty].allSatisfy(\.isFinite) else {
      throw NotebookStorageError.limitExceeded("element_basis_projection")
    }
    return result
  }
  static func spatialBounds(_ rect: CGRect,origin: WorldPoint = .zero) throws -> WorkspaceSpatialBounds {
    guard !rect.isNull,!rect.isInfinite,rect.width>=0,rect.height>=0,
      let minimum=origin.projectionOffset(x:rect.minX,y:rect.minY),
      let maximum=minimum.projectionOffset(x:rect.width,y:rect.height) else {
      throw NotebookStorageError.limitExceeded("element_group_projection")
    }
    return .init(origin:minimum,maximum:maximum)
  }
  static func validParent(_ parentID: String?, childID: String) -> Bool {
    guard let parentID else { return true }
    return !parentID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
      && parentID.utf16.count <= 120 && collaborationIdentity(parentID) != collaborationIdentity(childID)
  }
  static func validLocalFrame(_ frame: PageRect) -> Bool {
    [frame.x,frame.y,frame.width,frame.height].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
      && frame.width > 0 && frame.height > 0
  }
}
