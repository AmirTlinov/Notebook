public enum PencilPressure {
  public static func level(force: Double) -> Double {
    min(max(force, 0), 1)
  }
}

public enum PencilPressureOpacity {
  public static let maximumFloor = 0.6

  public static func value(force: Double, minimum: Double) -> Double {
    let floor = min(max(minimum, 0), maximumFloor)
    return floor + ((1 - floor) * PencilPressure.level(force: force))
  }
}

public enum PencilPressureWidth {
  public static func value(
    force: Double,
    minimum: Double,
    maximum: Double
  ) -> Double {
    let lowerBound = max(minimum, 0)
    let upperBound = max(maximum, lowerBound)
    return lowerBound
      + ((upperBound - lowerBound) * PencilPressure.level(force: force))
  }
}
