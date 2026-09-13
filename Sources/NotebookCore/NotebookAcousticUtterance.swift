import Foundation

/// Audio frames, not delayed ASR timestamps, delimit a local recognition request.
/// Energy only locates a phrase; the recognizer must still classify its address.
public struct NotebookAcousticUtterance: Sendable {
  public enum Boundary: Equatable, Sendable { case began(Int), ended }
  public private(set) var start: Int?
  public private(set) var silence: Double = 0
  private var candidate: Int?
  private var lastSound = 0, previousEnd = 0
  private var floorSamples = Array(repeating: -72.0, count: 10)
  public init() {}

  public mutating func append(rms: Double, frame: Int, count: Int, rate: Double) -> Boundary? {
    guard rms.isFinite, rms >= 0, frame >= 0, count > 0, rate > 0 else { return nil }
    let db = 20 * log10(max(rms, 0.000001))
    // The low energy quantile tracks a room's floor, not its loudest word.
    // A fixed -44 dB gate previously missed quiet iPad speech entirely.
    floorSamples.append(db)
    if floorSamples.count > 30 { floorSamples.removeFirst() }
    let sorted = floorSamples.sorted()
    let floor = sorted[min(sorted.count - 1, sorted.count / 5)]
    let threshold = min(-38, max(-60, floor + 9))
    let audible = db >= threshold
    let end = frame + count
    if audible {
      lastSound = end; silence = 0
      if candidate == nil { candidate = frame }
      if start == nil, Double(end - candidate!) / rate >= 0.08 {
        let beginning = max(previousEnd, candidate! - Int(rate * 0.2))
        start = beginning
        return .began(beginning)
      }
    } else {
      candidate = nil
      silence = Double(end - lastSound) / rate
      if start != nil, silence >= 0.8 {
        start = nil; previousEnd = end
        return .ended
      }
    }
    return nil
  }
}
