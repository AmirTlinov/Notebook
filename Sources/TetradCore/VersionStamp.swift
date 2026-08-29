import Foundation

public struct VersionStamp: Codable, Hashable, Sendable, Comparable {
  public let counter: UInt64
  public let actor: UUID

  public init(counter: UInt64, actor: UUID) {
    self.counter = counter
    self.actor = actor
  }

  public func advanced(by actor: UUID) -> Self {
    Self(counter: counter + 1, actor: actor)
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
    return lhs.actor.uuidString < rhs.actor.uuidString
  }
}
