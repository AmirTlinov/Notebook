import NotebookCore
import Foundation

/// Mounted consumers borrow accepted deltas. The model/journal remains the
/// only source of ink and history; this directory retains neither.
@MainActor
protocol NotebookPageInkConsumer: AnyObject {
  func receiveAcceptedInk(_ change: PreparedPageInkChange, suppressedIDs: Set<UUID>)
}

@MainActor
final class NotebookPageInkPublication {
  private struct Entry {
    let pageID: UUID
    weak var consumer: (any NotebookPageInkConsumer)?
  }
  private var entries: [ObjectIdentifier: Entry] = [:]

  func register(_ consumer: any NotebookPageInkConsumer, pageID: UUID) {
    entries[ObjectIdentifier(consumer)] = .init(pageID: pageID, consumer: consumer)
  }

  func remove(_ consumer: any NotebookPageInkConsumer) {
    entries[ObjectIdentifier(consumer)] = nil
  }

  func publish(_ change: PreparedPageInkChange, suppressedIDs: Set<UUID> = []) {
    entries = entries.filter { $0.value.consumer != nil }
    for entry in entries.values where entry.pageID == change.pageID {
      entry.consumer?.receiveAcceptedInk(change, suppressedIDs: suppressedIDs)
    }
  }
}

/// Issued only after the overlay verifies its installed source/materials.
struct PageElementErasurePresentation {
  let pageID: UUID
  let stamp: VersionStamp
  let erasures: [String: [InkElementErasure]]
}
