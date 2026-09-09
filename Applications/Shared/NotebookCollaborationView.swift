import NotebookCore
import SwiftUI

struct NotebookCollaborationView: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var showsHistory = false
  @State private var historyRequestedAt: ContinuousClock.Instant?
  @State private var pendingShow: CollaborationReference?
  private var contexts: [SharedContext] {
    model.sharedContexts.sorted { left, right in
      latestDate(left) > latestDate(right)
    }
  }
  private func latestDate(_ context: SharedContext) -> Date {
    max(context.entries.map(\.createdAt).max() ?? .distantPast,
      model.collaborationActions.first { $0.action.resolvedContextID == context.id }?.createdAt ?? .distantPast)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let question = model.agentQuestion {
        NotebookAgentQuestionCard(question: question).id(question.id)
      }
      if model.isPointing {
        Label("Укажите фрагмент · протяните для области", systemImage: "hand.point.up.left")
          .font(.callout).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      }
      if model.showsCollaborationNotice, let context = model.presentedSharedContext {
        let latest = model.collaborationActions.first { $0.action.resolvedContextID == context.id }
        HStack(alignment: .top, spacing: 8) {
          Button(action: openHistory) {
            VStack(alignment: .leading, spacing: 4) {
              Text(latest?.undo != nil ? "Ход отменён" : "Продолжение мысли").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              Text(latest?.action.summary ?? context.entries.last?.references.first?.label ?? "Общий фрагмент").font(.callout).lineLimit(3)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.accessibilityIdentifier("collaboration-notice-history")
          if let reference = latest.flatMap({ model.results(for: $0).first }) ?? context.entries.last?.references.first {
            Button("Показать") { model.requestShow(reference) }.frame(minHeight: 44).accessibilityIdentifier("collaboration-show")
          }
          if let latest, latest.undo == nil {
            Button("Отменить") { model.undoCollaboration(latest.id) }.frame(minHeight: 44).accessibilityIdentifier("collaboration-undo")
          }
          Button { model.dismissCollaborationNotice() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
            .accessibilityLabel("Скрыть уведомление").accessibilityIdentifier("collaboration-dismiss")
        }.buttonStyle(.plain).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      }
      // Keep the history target in the same place when the six-second notice
      // expires; removing a button under a finger can silently discard its tap.
      if !model.sharedContexts.isEmpty {
        Button(action: openHistory) {
          Label(model.activeSharedContext == nil ? "Совместные ходы" : "Общий фрагмент", systemImage: model.activeSharedContext == nil ? "clock.arrow.circlepath" : "scope")
            .font(.callout).padding(.horizontal, 14).frame(minHeight: 44)
        }.buttonStyle(.plain).background(.regularMaterial, in: Capsule()).accessibilityIdentifier("collaboration-history")
      }
    }
    .frame(maxWidth: 520, alignment: .leading)
    .task(id: model.collaborationPreparationKey) { await model.refreshCollaborationDetails() }
    .task {
      while !Task.isCancelled {
        await model.refreshReferenceStatuses()
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
    .sheet(isPresented: $showsHistory, onDismiss: {
      if let reference = pendingShow { pendingShow = nil; model.requestShow(reference) }
    }) {
      NavigationStack {
        List {
          ForEach(contexts) { context in
            Section {
              ForEach(context.entries) { entry in
                if let text = entry.text, !text.isEmpty {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(entry.author == .human ? "Вы" : "Ответ агента")
                      .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(text).textSelection(.enabled)
                  }
                }
                ForEach(entry.references) { reference in
                  VStack(alignment: .leading, spacing: 5) {
                    Label(entry.author == .human ? "Вы указали" : "Понимание агента", systemImage: entry.author == .human ? "hand.point.up.left" : "quote.bubble")
                      .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(reference.label.isEmpty ? model.locationTitle(for: reference) : reference.label)
                    Text(model.locationTitle(for: reference)).font(.caption).foregroundStyle(.secondary)
                    if let label = entry.requiresReview ? "Нужно рассмотреть заново" : model.referenceStatusLabel(reference) {
                      Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Показать фрагмент") { pendingShow = reference; showsHistory = false }.frame(minHeight: 44)
                  }.padding(.vertical, 4)
                }
              }
              ForEach(model.collaborationActions.filter { $0.action.resolvedContextID == context.id }) { action in
                actionCard(action)
              }
              if model.activeSharedContext?.id == context.id {
                Button("Снять указание") { model.selectSharedContext(nil) }.frame(minHeight: 44)
              } else {
                Button("Продолжить этот фрагмент") { model.selectSharedContext(context.id) }.frame(minHeight: 44)
              }
            } header: {
              Text(context.entries.first?.references.first.map { model.locationTitle(for: $0) } ?? "Самостоятельный ход")
            }
          }
        }
        .accessibilityIdentifier("collaboration-history-list")
        .buttonStyle(.borderless)
        .navigationTitle("Совместные ходы")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showsHistory = false } } }
      }.frame(minWidth: 360, minHeight: 400)
        .onAppear {
          if let start = historyRequestedAt {
            model.collaborationHistoryMounted(after: start.duration(to: .now))
            historyRequestedAt = nil
          }
        }
    }
  }

  private func openHistory() {
    historyRequestedAt = .now
    showsHistory = true
  }

  private func actionCard(_ action: CollaborationReceipt) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(action.action.summary).font(.headline)
      if !model.collaborationDetailsAreCurrent {
        Text("Проверяются результаты и доработки").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(Array(Set(model.continuations(for: action).map(continuationLabel))).sorted(), id: \.self) { label in
        Text(label).font(.caption).foregroundStyle(.secondary)
      }
      if let undo = action.undo {
        Text("Отменено полей: \(undo.restored)").font(.caption).foregroundStyle(.secondary)
        ForEach(Array(undo.preserved.enumerated()), id: \.offset) { _, field in
          Text("Сохранена ваша доработка · \(aspect(field.path))").font(.caption)
        }
      }
      ForEach(model.results(for: action)) { reference in
        Button { pendingShow = reference; showsHistory = false } label: {
          Label("Показать · \(model.locationTitle(for: reference))", systemImage: "scope").frame(minHeight: 44)
        }.accessibilityIdentifier("show-action-result")
      }
      if action.undo == nil { Button("Отменить этот ход") { model.undoCollaboration(action.id) }.frame(minHeight: 44) }
    }.padding(.vertical, 6)
  }

  private func aspect(_ path: [CollaborationPathComponent]) -> String {
    let names = path.compactMap { if case .field(let name) = $0 { return name }; return nil }
    return names.contains("frame") || names.contains("center") ? "положение" : names.contains("css") ? "оформление" : names.contains("state") || names.contains("records") ? "состояние" : "содержание"
  }
  private func continuationLabel(_ field: CollaborationContinuation) -> String {
    let owner = field.author == .human ? "Ваша доработка" : field.author == .removed ? "Удалено позднее" : "Продолжено агентом"
    return "\(owner) · \(aspect(field.path))"
  }
}

struct NotebookAttentionMarks: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  var body: some View {
    ZStack(alignment:.topLeading) {
      ForEach(model.contextEntries) { attention in
        ForEach(attention.references) { reference in
          if (attention.author == .human || model.showsCollaborationNotice), let rect = NotebookAttentionProjection.frame(reference,model:model,presence:presence) {
            mark(rect, human:attention.author == .human, label:(attention.author == .human ? "Указано" : "Понимание агента") + (model.referenceStatusLabel(reference).map { " · " + $0 } ?? ""), changed:attention.requiresReview)
          }
        }
      }
      if model.showsCollaborationNotice, let action = model.collaborationActions.first, action.undo == nil {
        TimelineView(.periodic(from:.now,by:1)) { context in
          if context.date.timeIntervalSince(action.createdAt) < 6 {
            ForEach(model.results(for:action)) { reference in
              if let rect = NotebookAttentionProjection.frame(reference,model:model,presence:presence) {
                mark(rect,human:false,label:"Добавлено",changed:false)
              }
            }
          }
        }
      }
      if let reference = model.highlightedReference, let rect = NotebookAttentionProjection.frame(reference,model:model,presence:presence) {
        mark(rect,human:false,label:"Результат",changed:model.referenceChanged(reference))
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
  private func mark(_ rect: CGRect,human:Bool,label:String,changed:Bool) -> some View {
    ZStack(alignment:.topLeading) {
      if human {
        RoundedRectangle(cornerRadius:4).stroke(.indigo,style:StrokeStyle(lineWidth:2,dash:[6,4]))
      } else {
        RoundedRectangle(cornerRadius:12).stroke(.teal,lineWidth:2)
      }
      Text(changed ? "\(label) · изменилось" : label).font(.caption2.weight(.semibold))
        .padding(.horizontal,5).padding(.vertical,2).background(.regularMaterial,in:Capsule()).offset(y:-20)
    }.frame(width:max(12,rect.width),height:max(12,rect.height)).position(x:rect.midX,y:rect.midY)
  }
}
