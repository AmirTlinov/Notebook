import Foundation
import NotebookCore

/// A terminal activation keeps its canonical origin, never a view's temporary
/// interaction flags or an earlier SwiftUI page-count projection.
@MainActor
struct DocumentLinkOrigin {
  let source: DocumentSourceSnapshot
  let state: DocumentStateSnapshot
  let runtimeID: UUID
  let generation: UInt64
  let renderToken: String
  let pageIndex: Int
  let presentationEpoch: UInt64

  var documentID: UUID { source.message.documentID }

  func hasSamePresentation(as other: Self) -> Bool {
    source === other.source && state === other.state && runtimeID == other.runtimeID
      && generation == other.generation && renderToken == other.renderToken
      && pageIndex == other.pageIndex && presentationEpoch == other.presentationEpoch
  }
}

@MainActor
struct DocumentLinkActivation {
  let origin: DocumentLinkOrigin
  let destination: DocumentLinkDestination
}
