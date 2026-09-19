import NotebookCore
import SwiftUI

/// One native paper prepares the requested folio. Presence advances only when
/// that exact source/page reports rendered pixels, not when a button is pressed.
struct MacDocumentSurface: View {
  @Environment(NotebookAppModel.self) private var model
  let document: DocumentDocument
  let state: DocumentStateJournal
  let onLayout: (DocumentPageLayout) -> Void
  // Readiness is replayed when SwiftUI updates its callback. Advancing the
  // controller sequence must not itself schedule another body update.
  @MainActor private final class Navigation {
    let id = UUID()
    var revision: UInt64 = 0
  }
  @State private var navigation = Navigation()

  var body: some View {
    let source = NotebookAppModel.documentPageSourceRevision(document)
    let request = model.documentPageSelection.flatMap { $0.documentID == document.id && $0.sourceRevision == source ? $0 : nil }
    let page = request?.pageIndex ?? model.presence?.documentPageIndex ?? 0
    DocumentWebView(document: document, state: state, isInteractive: true,
      selectedPageIndex: page, capturesSnapshot: true,
      onRenderReady: .init(onFailure: { failure in
        Task { @MainActor in
          guard model.documentPageSelection?.id == request?.id else { return }
          navigation.revision &+= 1
          model.acceptDocumentPageNavigationStatus(.init(controllerID: navigation.id, documentID: document.id,
            sourceRevision: source, revision: navigation.revision, requestID: request?.id, target: page,
            phase: .failed, failure: failure))
        }
      }) { ready in
        Task { @MainActor in
          guard model.documents[document.id]?.contentStamp == document.contentStamp,
            model.presence?.focusedItemID == document.id,
            model.documentPageSelection?.id == request?.id else { return }
          guard ready else { return }
          model.bindDocumentPageController(navigation.id, documentID: document.id, source: source)
          navigation.revision &+= 1
          _ = model.acceptDocumentPageLanding(.init(controllerID: navigation.id, documentID: document.id,
            sourceRevision: source, revision: navigation.revision, pageIndex: page, requestID: request?.id))
        }
      },
      onPageLayout: { layout in
        guard layout.pageCount(for: source) != nil else { return }
        model.acceptDocumentReadingLayout(layout, documentID: document.id)
        onLayout(layout)
        if layout.isComplete, page >= layout.pageCount { _ = model.selectDocumentPage(layout.pageCount - 1, documentID: document.id) }
      }, onLinkActivation: model.activateDocumentLink,
      onSourceChange: { try await model.commitDocumentSource(edit: $0) },
      onStateChange: { block, value in model.commitDocumentState(documentID: document.id, blockID: block, value: value, sourceVersion: document.sourceVersion(blockID: block)) },
      drafts: model.documentEditingSessions.filter { $0.edit.documentID == document.id },
      onDraftChange: model.saveDocumentDraft, onDraftDiscard: model.discardDocumentDraft,
      onStateCheckpoint: { try await model.checkpointDocumentState(documentID: document.id, blockID: $0, value: $1, sourceVersion: $2) },
      measurements: model.documentMeasurements)
      .overlay(alignment: .bottom) { if let failure = model.documentPageNavigationStatus?.failure {
        VStack { Text(failure.message); Button("Повторить") { model.retryDocumentPageNavigation() } }.padding().background(.regularMaterial)
      } }
      .onChange(of: source, initial: true) { _, _ in model.bindDocumentPageController(navigation.id, documentID: document.id, source: source) }
      .onDisappear { model.unbindDocumentPageController(navigation.id) }
  }
}
