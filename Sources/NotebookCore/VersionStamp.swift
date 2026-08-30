import Foundation

public struct VersionStamp: Codable, Hashable, Sendable, Comparable {
  /// Largest integer represented exactly by both Swift UInt64 and JavaScript Number.
  public static let maximumCounter: UInt64 = 9_007_199_254_740_991

  public let counter: UInt64
  public let actor: UUID

  public init(counter: UInt64, actor: UUID) {
    self.counter = counter
    self.actor = actor
  }

  public func advanced(by actor: UUID) -> Self? {
    guard counter < Self.maximumCounter else { return nil }
    return Self(counter: counter + 1, actor: actor)
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
    return lhs.actor.uuidString < rhs.actor.uuidString
  }
}
