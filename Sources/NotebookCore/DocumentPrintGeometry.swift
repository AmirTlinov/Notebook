import Foundation

/// Displayed PDF points, after the page's /Rotate, with a top-left origin.
public struct DocumentPrintRect: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double
}

public struct DocumentPrintPage: Codable, Equatable, Sendable {
  public let mediaBoxX: Double
  public let mediaBoxY: Double
  public let mediaBoxWidth: Double
  public let mediaBoxHeight: Double
  public let rotation: Int
  public var width: Double { rotation == 90 || rotation == 270 ? mediaBoxHeight : mediaBoxWidth }
  public var height: Double { rotation == 90 || rotation == 270 ? mediaBoxWidth : mediaBoxHeight }
  public init(mediaBoxX: Double = 0, mediaBoxY: Double = 0, mediaBoxWidth: Double, mediaBoxHeight: Double, rotation: Int = 0) {
    self.mediaBoxX = mediaBoxX; self.mediaBoxY = mediaBoxY
    self.mediaBoxWidth = mediaBoxWidth; self.mediaBoxHeight = mediaBoxHeight
    self.rotation = ((rotation % 360)+360) % 360
  }
  public init(width: Double, height: Double) { self.init(mediaBoxWidth: width, mediaBoxHeight: height) }
  /// PDF annotations and destinations already include the content transform.
  /// Apply this same final projection used for source and interactive boxes.
  public func projectPDF(x: Double, y: Double, width: Double, height: Double) -> DocumentPrintRect {
    projectedBounds(x: x, y: y, width: width, height: height, content: .identity)
  }
  func projectPDF(_ point: PrintPoint) -> PrintPoint {
    let x = point.x-mediaBoxX, y = point.y-mediaBoxY
    switch rotation {
    case 90: return .init(x: y, y: x)
    case 180: return .init(x: mediaBoxWidth-x, y: y)
    case 270: return .init(x: mediaBoxHeight-y, y: mediaBoxWidth-x)
    default: return .init(x: x, y: mediaBoxHeight-y)
    }
  }
  func projectedBounds(x: Double, y: Double, width: Double, height: Double, content: PrintTransform) -> DocumentPrintRect {
    let points = [PrintPoint(x: x, y: y), .init(x: x+width, y: y), .init(x: x, y: y+height), .init(x: x+width, y: y+height)]
      .map { projectPDF(content.apply($0)) }
    let xs = points.map(\.x), ys = points.map(\.y)
    return .init(x: xs.min()!, y: ys.min()!, width: xs.max()!-xs.min()!, height: ys.max()!-ys.min()!)
  }
}

struct PrintPoint { let x: Double, y: Double }

/// Only the transformation grammar emitted by the pinned XeTeX driver. The
/// stream is generated at shipout; no PDF operators or TeX source are guessed.
struct PrintTransform {
  var a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, e: Double = 0, f: Double = 0
  static let identity = Self()
  func apply(_ p: PrintPoint) -> PrintPoint { .init(x: a*p.x+c*p.y+e, y: b*p.x+d*p.y+f) }
  func concatenating(_ rhs: Self) -> Self {
    .init(a: a*rhs.a+c*rhs.b, b: b*rhs.a+d*rhs.b, c: a*rhs.c+c*rhs.d, d: b*rhs.c+d*rhs.d,
      e: a*rhs.e+c*rhs.f+e, f: b*rhs.e+d*rhs.f+f)
  }
  static func shipout(_ description: Substring, pivot: PrintPoint) throws -> Self {
    let tokens = description.split(whereSeparator: \.isWhitespace)
    var index = 0, x = 1.0, y = 1.0, degrees = 0.0, matrix: Self?, keys: Set<String> = []
    func number() throws -> Double {
      guard index < tokens.count, let value = Double(tokens[index]), value.isFinite, abs(value) <= 1_000_000 else { throw unsupported() }
      index += 1; return value
    }
    while index < tokens.count {
      let key = String(tokens[index]); index += 1
      guard keys.insert(key).inserted else { throw unsupported() }
      switch key {
      case "scale": x = try number(); y = x
      case "xscale": x = try number()
      case "yscale": y = try number()
      case "rotate": degrees = try number()
      case "matrix": matrix = try .init(a: number(), b: number(), c: number(), d: number(), e: number(), f: number())
      default: throw unsupported()
      }
    }
    guard !(keys.contains("scale") && (!keys.isDisjoint(with: ["xscale", "yscale"]))),
      matrix == nil || keys.count == 1 else { throw unsupported() }
    let angle = degrees * .pi/180
    var result = matrix ?? .init(a: x*cos(angle), b: x*sin(angle), c: -y*sin(angle), d: y*cos(angle))
    guard abs(result.a*result.d-result.b*result.c) >= 0.000001 else { throw unsupported() }
    // Matches dvipdfmx btrans: transforms are anchored at the current DVI point.
    result.e += (1-result.a)*pivot.x-result.c*pivot.y
    result.f += (1-result.d)*pivot.y-result.b*pivot.x
    return result
  }
  static func unsupported() -> CollaborationError {
    .init("unsupported_print_transform", "Печатная карта содержит неподдерживаемое преобразование координат. Используйте обычные команды LaTeX для масштаба и ориентации страницы.")
  }
}
