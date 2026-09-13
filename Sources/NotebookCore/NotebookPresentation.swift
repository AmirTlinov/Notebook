import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A capability for one settled view of one foreground iPad run, not a camera owner.
public struct NotebookPresentationView: Codable, Equatable, Sendable {
  public let deviceID: UUID
  public let sessionID: UUID
  public let sequence: UInt64
  public let nonce: UUID
  public init(deviceID: UUID, sessionID: UUID, sequence: UInt64, nonce: UUID = UUID()) {
    self.deviceID = deviceID; self.sessionID = sessionID; self.sequence = sequence
    self.nonce = nonce
  }
}

public struct NotebookPresentationRegion: Codable, Equatable, Sendable {
  public let origin: WorldPoint
  public let width: Double
  public let height: Double
  public init(origin: WorldPoint, width: Double, height: Double) {
    self.origin = origin; self.width = width; self.height = height
  }
  public var isValid: Bool {
    origin.isValid && width.isFinite && height.isFinite && width >= 1 && height >= 1
      && width <= 100_000 && height <= 100_000
      && origin.addressOffset(x: width, y: height) != nil
  }
  public func fittedCamera(viewport: SpatialPoint) -> SpatialCamera? {
    guard isValid, viewport.isValid, viewport.x > 0, viewport.y > 0,
      let center = origin.addressOffset(x: width / 2, y: height / 2) else { return nil }
    let scale = min(viewport.x * 0.8 / width, viewport.y * 0.8 / height)
    return .init(center: center, scale: min(SpatialCamera.maximumScale, max(SpatialCamera.minimumScale, scale)))
  }
}

/// A short declarative script. SVG uses board-world points, including the paper
/// currently shown there; it never becomes a stored element or an ink action.
public struct NotebookPresentationStep: Codable, Equatable, Sendable {
  public let duration: Double
  public let transition: Double
  public let camera: SpatialCamera?
  public let focus: NotebookPresentationRegion?
  public let svg: String?
  public let bounds: NotebookPresentationRegion?
  public init(duration: Double = 3, transition: Double = 0.3, camera: SpatialCamera? = nil,
    focus: NotebookPresentationRegion? = nil, svg: String? = nil, bounds: NotebookPresentationRegion? = nil) {
    self.duration = duration; self.transition = transition; self.camera = camera
    self.focus = focus; self.svg = svg; self.bounds = bounds
  }
  public var isValid: Bool {
    duration.isFinite && (0.5...10).contains(duration)
      && transition.isFinite && (0...1).contains(transition) && transition <= duration
      && !(camera != nil && focus != nil) && (camera?.isValid ?? true) && (focus?.isValid ?? true)
      && ((svg == nil && bounds == nil) || (bounds?.isValid == true && svg.map(NotebookPresentationSVG.isValid) == true))
      && (camera != nil || focus != nil || svg != nil)
  }
}

public struct NotebookPresentationRequest: Codable, Equatable, Sendable {
  public let id: UUID
  public let view: NotebookPresentationView
  public let steps: [NotebookPresentationStep]
  public init(id: UUID, view: NotebookPresentationView, steps: [NotebookPresentationStep]) {
    self.id = id; self.view = view; self.steps = steps
  }
  public var isValid: Bool {
    !steps.isEmpty && steps.count <= 12 && steps.allSatisfy(\.isValid)
      && steps.reduce(0, { $0 + $1.duration }) <= 60
      && ((try? JSONEncoder().encode(self).count) ?? .max) <= 192 * 1024
  }
}

public struct NotebookPresentationReceipt: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case sent, playing, completed, interrupted, rejected, unavailable
  }
  public let id: UUID
  public let status: Status
  public let step: Int
  public let reason: String?
  public init(id: UUID, status: Status, step: Int = 0, reason: String? = nil) {
    self.id = id; self.status = status; self.step = step; self.reason = reason
  }
  public var isTerminal: Bool { status != .sent && status != .playing }
}

public enum NotebookPresentationMessage: Codable, Equatable, Sendable {
  case play(NotebookPresentationRequest, expiresAt: Date)
  case cancel(id: UUID, sessionID: UUID)
  case receipt(NotebookPresentationReceipt)
  public var isValid: Bool {
    switch self {
    case .play(let request, let expiry): request.isValid && expiry.timeIntervalSince1970.isFinite
    case .cancel: true
    case .receipt(let receipt): (0...12).contains(receipt.step) && (receipt.reason?.utf8.count ?? 0) <= 240
    }
  }
}

/// No executable source, external entities, links or embedded documents. The
/// WebKit display adds a no-network CSP and disables content JavaScript too.
public enum NotebookPresentationSVG {
  public static func isValid(_ source: String) -> Bool {
    guard !source.isEmpty, source.utf8.count <= 48 * 1024,
      !source.localizedCaseInsensitiveContains("<!DOCTYPE"),
      !source.localizedCaseInsensitiveContains("<!ENTITY") else { return false }
    let validator = SVGValidator(), parser = XMLParser(data: Data(source.utf8))
    parser.shouldResolveExternalEntities = false; parser.delegate = validator
    return parser.parse() && validator.valid && validator.count > 0
  }
}

private final class SVGValidator: NSObject, XMLParserDelegate {
  var count = 0
  var valid = true
  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String]) {
    count += 1
    let name = elementName.lowercased().split(separator: ":").last.map(String.init) ?? ""
    if (count == 1 && name != "svg") || count > 2048
      || ["script", "foreignobject", "iframe", "image", "audio", "video", "a"].contains(name)
      || attributes.contains(where: { key, value in
        (key.lowercased().split(separator: ":").last?.hasPrefix("on") ?? false)
          || (key.lowercased().hasSuffix("href") && !value.hasPrefix("#"))
      }) { valid = false; parser.abortParsing() }
  }
}
