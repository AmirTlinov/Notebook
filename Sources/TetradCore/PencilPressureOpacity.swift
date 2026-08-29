public enum PencilPressureOpacity {
  public static func value(force: Double, minimum: Double) -> Double {
    let floor = min(max(minimum, 0), 1)
    let pressure = min(max(force, 0), 1)
    return floor + ((1 - floor) * pressure)
  }
}
