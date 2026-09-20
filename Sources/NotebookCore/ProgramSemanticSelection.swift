import Foundation
import CoreGraphics

/// Data supplied by an untrusted program about one selected object. It never
/// expands a reference's permission and is not a claim of scientific accuracy.
public struct ProgramSemanticSelection: Codable, Equatable, Sendable {
  public struct Anchor: Codable, Equatable, Sendable { public let x: Double; public let y: Double }
  public struct Measurement: Codable, Equatable, Sendable {
    public let label: String
    public let value: Double
    public let unit: String
  }
  public let objectID: String
  public let label: String
  public let anchor: Anchor
  public let values: [Measurement]
  public let model: JSONValue

  public func mapped(from frame: PageRect, into region: PageRect, transform:CGAffineTransform = .identity) -> Self? {
    let point=CGPoint(x:frame.x+anchor.x*frame.width,y:frame.y+anchor.y*frame.height).applying(transform)
    let x = (point.x-region.x)/region.width
    let y = (point.y-region.y)/region.height
    let result = Self(objectID: objectID, label: label, anchor: .init(x: x, y: y), values: values, model: model)
    return (try? result.validate()) != nil ? result : nil
  }

  public func validate() throws {
    guard !objectID.isEmpty, objectID.utf8.count <= 128,
      !label.isEmpty, label.utf8.count <= 256,
      anchor.x.isFinite, anchor.y.isFinite, (0...1).contains(anchor.x), (0...1).contains(anchor.y),
      values.count <= 8, values.allSatisfy({ !$0.label.isEmpty && $0.label.utf8.count <= 128
        && $0.value.isFinite && $0.unit.utf8.count <= 64 }), model.isValid,
      try JSONEncoder().encode(self).count <= 16_384 else {
      throw CollaborationError("invalid_program_semantic", "Семантика выбранного объекта не ограничена или некорректна.")
    }
  }
}
