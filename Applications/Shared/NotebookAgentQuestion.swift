import Foundation
import NotebookCore

/// A composer keeps the physical address of its own question. Receiving an
/// answer changes neither first responder nor the current camera/selection.
struct NotebookAgentQuestion: Equatable, Sendable, Identifiable {
  let contextID: UUID
  let entryID: UUID
  let references: [CollaborationReference]
  var id: UUID { contextID }
}

#if os(iOS)
import SwiftUI

/// A frozen indication has no second composer or execution mode.
struct NotebookAgentQuestionCard: View {
  @Environment(NotebookAppModel.self) private var model
  let question: NotebookAgentQuestion
  let maximumHeight: CGFloat
  var body: some View {
    HStack {
      Button { model.chat?.expanded = true } label: {
        Label(question.references.first?.label ?? "Закреплённый фрагмент", systemImage: "bubble.left.and.text.bubble.right")
          .lineLimit(2).frame(minHeight: 44)
      }.accessibilityIdentifier("agent-question-open-chat")
      Button { model.dismissAgentQuestion() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
        .accessibilityIdentifier("agent-question-dismiss").accessibilityLabel("Снять указание")
    }
    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    .accessibilityIdentifier("agent-question-card")
  }
}
#endif
