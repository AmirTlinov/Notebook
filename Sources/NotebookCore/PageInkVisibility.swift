import Foundation

/// The gate of an immutable measured action, not its colour or a replacement
/// stroke. A later explicit inverse can reopen it; an old drawing cannot.
public struct PageInkVisibility: Codable, Equatable, Sendable {
  public let isActive: Bool
  public let stateStamp: VersionStamp?

  public init(isActive: Bool, stateStamp: VersionStamp? = nil) {
    self.isActive = isActive; self.stateStamp = stateStamp
  }

  public var isValid: Bool { stateStamp.map { $0.counter <= VersionStamp.maximumCounter } ?? true }

  public func merging(_ other: Self) throws -> Self {
    guard isValid, other.isValid else { throw PageInkDrawing.InkError.invalidDrawing }
    switch (stateStamp, other.stateStamp) {
    case (nil, nil): return isActive ? other : self
    case (nil, _?): return other
    case (_?, nil): return self
    case (let a?, let b?):
      if a == b {
        guard isActive == other.isActive else { throw PageInkDrawing.InkError.actionIDConflict }
        return self
      }
      return a > b ? self : other
    }
  }
}
