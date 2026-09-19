import NotebookCore
import SwiftUI

struct NotebookAttentionMarks: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  var body: some View {
    ZStack(alignment:.topLeading) {
      // Only a context target draws a context outline. An item or element
      // already presents the same session through its physical editing owner.
      if model.selectionSession.target == .context, let question = model.agentQuestion,
        let rect = question.references.compactMap({ NotebookAttentionProjection.frame($0, model: model, presence: presence) })
          .reduce(nil as CGRect?, { $0?.union($1) ?? $1 }) {
        mark(rect, human: true)
      }
      if let reference = model.highlightedReference, let rect = NotebookAttentionProjection.frame(reference,model:model,presence:presence) {
        mark(rect, human: false)
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
  private func mark(_ rect: CGRect, human: Bool) -> some View {
    RoundedRectangle(cornerRadius: 4)
      .stroke(human ? Color.indigo.opacity(0.55) : Color.teal.opacity(0.6), lineWidth: 1)
      .frame(width: max(12, rect.width), height: max(12, rect.height))
      .position(x: rect.midX, y: rect.midY)
  }
}
