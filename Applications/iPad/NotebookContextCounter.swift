import NotebookCore
import SwiftUI

/// Both chat presentations expose the same pinned references, not a board notification.
struct NotebookContextCounter: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var showsReferences = false

  var body: some View {
    if let question = model.agentQuestion, !question.references.isEmpty {
      Button { showsReferences.toggle() } label: {
        Text(question.references.count.formatted())
          .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
          .foregroundStyle(Color.accentColor).frame(minWidth: 18, minHeight: 18)
          .background(Color.accentColor.opacity(0.09), in: Circle())
          .frame(width: 28, height: 44).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Материал для агента")
      .accessibilityValue("\(question.references.count)")
      .accessibilityIdentifier("notebook-context-count")
      .popover(isPresented: $showsReferences) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Материал для разговора").font(.subheadline.weight(.semibold))
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              ForEach(question.references) { reference in
                VStack(alignment: .leading, spacing: 3) {
                  Text(model.locationTitle(for: reference)).font(.subheadline).lineLimit(2)
                  if let status = model.referenceStatusLabel(reference) {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.scrollBounceBehavior(.basedOnSize)
          Button("Снять выделение", systemImage: "xmark") {
            showsReferences = false
            model.dismissAgentQuestion()
          }.frame(minHeight: 44).accessibilityIdentifier("notebook-context-clear")
        }.padding(16).frame(width: 260, height: min(280, 118 + CGFloat(question.references.count) * 48))
          .background(NotebookControlRegion(gate: model.inputGate))
          .presentationCompactAdaptation(.popover)
      }
    }
  }
}
