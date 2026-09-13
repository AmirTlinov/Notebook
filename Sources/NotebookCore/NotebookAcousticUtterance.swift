import Foundation

/// The source audio clock owns speech boundaries. Display gain is an output,
/// never an input to either address admission or the end of a request.
public struct NotebookAcousticUtterance: Sendable {
  public enum Boundary: Equatable, Sendable { case began(Int), ended }
  public struct Sample: Sendable {
    public let frame: Int
    public let count: Int
    public let rate: Double
    public let rms: Double
    public let peak: Double
    public let noiseDB: Double
    public let speaking: Bool
    public let silence: Double
    public let boundary: Boundary?
    public var end: Int { frame + count }
    public var level: Double {
      // Quiet microphones still have a visible range. Keep the ambient floor
      // near the baseline without flattening a quiet person's voice to zero.
      let db = 20 * log10(max(rms, peak * 0.25, 0.000_001))
      return min(1, max(0, (db - min(-60, noiseDB + 3)) / 35))
    }
  }
  public private(set) var start: Int?
  public private(set) var silence: Double = 0
  private var candidate: Int?
  private var lastSound = 0, previousEnd = 0
  private var noiseDB: Double?
  private var quiet: [Double] = []
  private var speaking = false

  public init() {}
  public mutating func append(rms: Double, peak: Double = 0, frame: Int, count: Int, rate: Double) -> Sample {
    let db = 20 * log10(max(rms, 0.000_001))
    // The initial sample establishes this microphone's floor; a quiet input
    // route must not inherit a threshold calibrated for another microphone.
    if noiseDB == nil { noiseDB = max(-90, db) }
    let floor = noiseDB!
    let onset = max(-75, floor + 9), continuation = max(-78, floor + 5)
    let audible = db >= (speaking ? continuation : onset)
    let end = frame + count
    var boundary: Boundary?
    if audible {
      lastSound = end; silence = 0
      if candidate == nil { candidate = frame }
      if Double(end - candidate!) / rate >= 0.08 {
        speaking = true
        if start == nil {
          let beginning = max(previousEnd, candidate! - Int(rate * 0.2))
          start = beginning; boundary = .began(beginning)
        }
      }
    } else {
      candidate = nil; speaking = false
      silence = Double(end - lastSound) / rate
      if start != nil, silence >= 0.8 { start = nil; previousEnd = end; boundary = .ended }
    }
    // Background learning uses non-speech only. A sustained spoken sentence
    // cannot raise its own floor and turn its quiet syllables into silence.
    if !audible {
      quiet.append(db); if quiet.count > 30 { quiet.removeFirst() }
      let sorted = quiet.sorted(), estimate = sorted[sorted.count / 5]
      noiseDB = floor + (estimate - floor) * (estimate < floor ? 0.2 : 0.05)
    }
    return .init(frame: frame, count: count, rate: rate, rms: rms, peak: peak,
      noiseDB: noiseDB!, speaking: speaking, silence: silence, boundary: boundary)
  }
}
