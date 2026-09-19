import Foundation

public enum PencilPressure {
  public static func normalized(force: Double, maximum: Double) -> Double {
    guard force.isFinite, maximum.isFinite, maximum > 0 else { return 0 }
    return level(force: force / maximum)
  }

  static func level(force: Double) -> Double {
    min(max(force, 0), 1)
  }
}

public enum PencilPressureSmoothing {
  public static let responseTime = 0.012

  public static func value(
    force: Double,
    previous: Double?,
    elapsed: Double?
  ) -> Double {
    let current = force.isFinite ? PencilPressure.level(force: force) : 0
    guard let previous, previous.isFinite, let elapsed, elapsed.isFinite else {
      return current
    }
    let prior = PencilPressure.level(force: previous)
    let response = 1 - exp(-max(elapsed, 0) / responseTime)
    return prior + ((current - prior) * response)
  }
}

public enum PencilPressureOpacity {
  public static let maximumFloor = 0.6

  public static func value(force: Double, minimum: Double) -> Double {
    let floor = min(max(minimum, 0), maximumFloor)
    let pressure = PencilPressure.level(force: force)
    let response = pressure * (2 - pressure)
    return floor + ((1 - floor) * response)
  }
}
