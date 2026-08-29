public enum PencilPressureOpacity {
  public static let maximumFloor = 0.6

  public static func value(force: Double, minimum: Double) -> Double {
    let floor = min(max(minimum, 0), maximumFloor)
    let pressure = min(max(force, 0), 1)
    return floor + ((1 - floor) * pressure)
  }
}
