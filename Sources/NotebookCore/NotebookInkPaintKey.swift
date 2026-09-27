import Foundation

/// One original accepted contact has one painter address. Conversion changes
/// its representation and pose, never that address. Page and world histories
/// retain their respective native order; no authored z index is substituted.
public enum NotebookInkPaintKey: Equatable, Comparable, Sendable {
  case page(sequence:UInt64,id:UUID)
  case spatial(stamp:VersionStamp,id:UUID)
  public static func <(a:Self,b:Self)->Bool {
    switch (a,b) {
    case (.page(let x,let i),.page(let y,let j)):
      return x == y ? i.uuidString < j.uuidString : x < y
    case (.spatial(let x,let i),.spatial(let y,let j)):
      return x == y ? i.uuidString < j.uuidString : x < y
    default: preconditionFailure("One ink plane cannot mix page and world painter addresses")
    }
  }
  public var actionID:UUID {
    switch self { case .page(_,let id),.spatial(_,let id):id }
  }

  /// Ordinary authored elements keep their existing relative order below the
  /// physical ink plane. Raw and converted contacts share their original key.
  public static func ordering(_ authoredOrder:[String], keys:[String:Self])->[String] {
    authoredOrder.filter{keys[$0] == nil} + authoredOrder.filter{keys[$0] != nil}.sorted {
      let a=keys[$0]!,b=keys[$1]!
      return a == b ? $0 < $1 : a < b
    }
  }
}
