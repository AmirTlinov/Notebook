import Foundation

/// Display-link cadence is evidence of main-thread scheduling, not a GPU
/// presentation receipt. Retain a fixed recent window even during long input.
public struct InputFrameStatistics: Sendable {
  public static let capacity = 4096
  private var intervals: [Double] = []
  private var nextIndex = 0
  private var previousTimestamp: Double?
  private var previousExpectedInterval: Double?
  private var total = 0
  private var unserviced = 0
  private var maximum = 0.0

  public init() {}

  public mutating func record(timestamp: Double, expectedInterval: Double) {
    guard timestamp.isFinite, expectedInterval.isFinite, expectedInterval > 0 else { return }
    defer { previousTimestamp = timestamp; previousExpectedInterval = expectedInterval }
    guard let previousTimestamp, timestamp > previousTimestamp else { return }
    let interval = timestamp - previousTimestamp
    total += 1
    maximum = max(maximum, interval)
    let expected = max(previousExpectedInterval ?? expectedInterval, expectedInterval)
    unserviced += max(0, Int(min(1_000_000, (interval / expected).rounded())) - 1)
    if intervals.count < Self.capacity { intervals.append(interval) }
    else { intervals[nextIndex] = interval; nextIndex = (nextIndex + 1) % Self.capacity }
  }

  public var summary: InputFrameSummary {
    let sorted = intervals.sorted()
    let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    return .init(totalIntervals: total, retainedIntervals: intervals.count,
      recentIntervalP95MS: p95 * 1000, maximumIntervalMS: maximum * 1000,
      estimatedUnservicedIntervals: unserviced)
  }
}

public struct InputFrameSummary: Codable, Equatable, Sendable {
  public let totalIntervals: Int
  public let retainedIntervals: Int
  public let recentIntervalP95MS: Double
  public let maximumIntervalMS: Double
  public let estimatedUnservicedIntervals: Int
}
