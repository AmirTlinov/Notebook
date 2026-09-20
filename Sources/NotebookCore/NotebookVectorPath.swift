import Foundation
import CoreGraphics

/// Closed Bézier contours in the element's normalized coordinates. Boolean
/// operations retain curves and holes, not raster masks or an operation tree.
public struct NotebookVectorPath: Codable, Equatable, Sendable {
  public struct Command: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case move, line, quad, curve, close }
    public let kind: Kind
    public let points: [SpatialPoint]
    public init(kind: Kind, points: [SpatialPoint]) { self.kind = kind; self.points = points }
  }
  public let commands: [Command]
  /// Validity belongs to the immutable commands, not each pose/style carrying
  /// them. It is derived once at admission and never serialized or cached as a
  /// second geometry body.
  public let isValid: Bool
  private enum CodingKeys: String, CodingKey { case commands }
  public init(commands: [Command]) {
    self.commands = commands
    isValid = Self.validate(commands)
  }
  public init(from decoder: Decoder) throws {
    self.init(commands:try decoder.container(keyedBy:CodingKeys.self).decode([Command].self,forKey:.commands))
  }
  public init(path: CGPath, frame: CGRect) {
    var commands: [Command] = []
    path.applyWithBlock { pointer in
      let element = pointer.pointee
      let kind: Command.Kind, count: Int
      switch element.type {
      case .moveToPoint: kind = .move; count = 1
      case .addLineToPoint: kind = .line; count = 1
      case .addQuadCurveToPoint: kind = .quad; count = 2
      case .addCurveToPoint: kind = .curve; count = 3
      case .closeSubpath: kind = .close; count = 0
      @unknown default: return
      }
      commands.append(.init(kind:kind,points:(0..<count).map {
        .init(x:(element.points[$0].x-frame.minX)/frame.width,y:(element.points[$0].y-frame.minY)/frame.height)
      }))
    }
    self.init(commands:commands)
  }
  private static func validate(_ commands: [Command]) -> Bool {
    guard !commands.isEmpty, commands.count <= 8192 else { return false }
    var open = false
    for command in commands {
      let count: Int
      switch command.kind {
      case .move: guard !open else { return false }; open = true; count = 1
      case .close: guard open else { return false }; open = false; count = 0
      case .line: guard open else { return false }; count = 1
      case .quad: guard open else { return false }; count = 2
      case .curve: guard open else { return false }; count = 3
      }
      guard command.points.count == count,
        command.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1e6 && abs($0.y) <= 1e6 }) else { return false }
    }
    return !open
  }
  public func path(in rect: CGRect) -> CGPath {
    let result = CGMutablePath()
    for command in commands {
      let p = command.points.map { CGPoint(x:rect.minX+$0.x*rect.width,y:rect.minY+$0.y*rect.height) }
      switch command.kind {
      case .move: result.move(to:p[0])
      case .line: result.addLine(to:p[0])
      case .quad: result.addQuadCurve(to:p[1],control:p[0])
      case .curve: result.addCurve(to:p[2],control1:p[0],control2:p[1])
      case .close: result.closeSubpath()
      }
    }
    return result
  }
}
