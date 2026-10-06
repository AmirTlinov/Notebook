import Foundation

/// A finite SQL allowance belongs to the admitted operation. The connection's
/// one progress handler charges every active owner, including nested helpers.
final class NotebookSQLExecutionBudget {
  let reason: String
  private var maximumSteps: Int
  private(set) var steps = 0
  private(set) var exhausted = false

  init(steps: Int, reason: String) {
    precondition(steps >= 0)
    maximumSteps = steps; self.reason = reason
  }

  func tighten(remainingSteps: Int) {
    precondition(remainingSteps >= 0)
    let (limit, overflow) = steps.addingReportingOverflow(remainingSteps)
    maximumSteps = min(maximumSteps, overflow ? Int.max : limit)
  }

  func advance() -> Bool {
    guard !exhausted else { return false }
    if steps == maximumSteps { exhausted = true; return false }
    steps += 1
    return true
  }
}
