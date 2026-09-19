import NotebookCore
import SwiftUI

/// Both chat presentations expose the same pinned references, not a board notification.
struct NotebookContextCounter: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var showsReferences = false
  private struct ProgramMenu: Identifiable {
    let id = UUID()
    let programs: [NotebookAttentionProjection.ProgramChoice]
  }
  @State private var programMenu: ProgramMenu?

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
          if model.canFreezeProgramForAttention {
            if model.hasFrozenProgramForAttention {
              Text("Кадр зафиксирован. Отправьте вопрос или снимите выделение, чтобы продолжить.")
                .font(.caption).foregroundStyle(.secondary)
            } else { Button("Зафиксировать кадр", systemImage: "pause") {
              Task { await model.freezeProgramForAttention(); showsReferences = false }
            }.disabled(model.selectionSession.isResolvingContext)
              .frame(minHeight: 44).accessibilityIdentifier("notebook-context-freeze-program")
            }
          }
          Button("Снять выделение", systemImage: "xmark") {
            showsReferences = false
            model.dismissAgentQuestion()
          }.frame(minHeight: 44).accessibilityIdentifier("notebook-context-clear")
        }.padding(16).frame(width: 260, height: min(280, 118 + CGFloat(question.references.count) * 48 + (model.canFreezeProgramForAttention ? 56 : 0)))
          .background(NotebookControlRegion(gate: model.inputGate))
          .presentationCompactAdaptation(.popover)
      }
    } else {
      Button {
        programMenu = .init(programs: NotebookAttentionProjection.programChoices(model: model))
      } label: {
        Image(systemName: "paperclip").font(.system(size: 14)).foregroundStyle(.secondary)
          .frame(width: 28, height: 44).contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel("Добавить материал для разговора")
        .accessibilityIdentifier("notebook-context-add")
        .popover(item: $programMenu) { menu in
          VStack(alignment: .leading, spacing: 12) {
            Text("Материал для разговора").font(.subheadline.weight(.semibold))
            if menu.programs.isEmpty {
              Text("Укажите объект или область на странице.").font(.subheadline).foregroundStyle(.secondary)
            } else {
              ForEach(menu.programs) { program in
                Button(program.label) {
                  programMenu = nil
                  model.selectProgramForAttention(program)
                }.frame(minHeight: 44).lineLimit(2).accessibilityIdentifier("notebook-context-program-" + program.elementID)
              }
            }
          }.padding(16).frame(width: 260)
            .background(NotebookControlRegion(gate: model.inputGate))
            .presentationCompactAdaptation(.popover)
        }
    }
  }
}
