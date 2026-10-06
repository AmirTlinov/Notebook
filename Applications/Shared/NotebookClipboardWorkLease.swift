import Foundation

/// Body workers retain this value through actual completion. An accepted write
/// takes the same reservation; only its FIFO can then release the charge.
final class NotebookClipboardWorkLease: @unchecked Sendable {
  let reservation:NotebookPersistenceAdmission.Reservation
  private let lock=NSLock()
  private var finished=false
  private let release:@Sendable ()->Void
  init(reservation:NotebookPersistenceAdmission.Reservation,release:@escaping @Sendable ()->Void) {
    self.reservation=reservation;self.release=release
  }
  func finish() {
    let shouldRelease=lock.withLock {
      guard !finished else { return false }
      finished=true;return true
    }
    if shouldRelease { release() }
  }
  deinit { finish() }
}
