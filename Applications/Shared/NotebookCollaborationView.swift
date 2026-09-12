import NotebookCore
import SwiftUI

struct NotebookCollaborationView: View {
  @Environment(NotebookAppModel.self) private var model
  @Binding var showsHistory: Bool
  @State private var historyRequestedAt: ContinuousClock.Instant?
  @State private var pendingShow: CollaborationReference?
  @State private var historyDirectory: SharedContextDirectory?
  @State private var directoryError: String?
  @State private var loadingDirectory = false
  private var contexts: [SharedContextSummary] {
    historyDirectory?.contexts ?? model.sharedContexts
  }
  var body: some View {
    Color.clear.frame(width: 0, height: 0)
    .onChange(of: showsHistory) { if showsHistory { historyRequestedAt = .now } }
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
              NavigationLink("Открыть историю фрагмента") {
                NotebookContextHistoryView(contextID: context.id) { reference in
                  pendingShow = reference; showsHistory = false
                }
              }.accessibilityIdentifier("context-history-" + context.id.uuidString.lowercased())
              ForEach(context.previewEntries) { entry in
                if let text = entry.text, !text.isEmpty {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(entry.author == .human ? "Вы" : "Ответ агента")
                      .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)).textSelection(.enabled)
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
              Text(context.previewEntries.first?.references.first.map { model.locationTitle(for: $0) } ?? "Самостоятельный ход")
            }
          }
        }
        .accessibilityIdentifier("collaboration-history-list")
        .safeAreaInset(edge: .bottom) {
          VStack {
            if let directoryError { Text(directoryError).font(.caption).accessibilityIdentifier("context-directory-error") }
            HStack {
              Button { Task { await loadDirectory() } } label: { Text("К новым фрагментам").frame(minHeight: 44) }
              if directoryError == nil, let directory = historyDirectory, let after = directory.nextContextID {
                Button { Task { await loadDirectory(after: after, cursor: directory.readCursor) } } label: { Text("Следующие фрагменты").frame(minHeight: 44) }
                  .accessibilityIdentifier("context-directory-next")
              }
            }.disabled(loadingDirectory).padding(8)
          }.background(.regularMaterial)
        }
        .task { await loadDirectory() }
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

  private func loadDirectory(after: UUID? = nil, cursor: String? = nil) async {
    guard !loadingDirectory else { return }
    loadingDirectory = true
    defer { loadingDirectory = false }
    let store = model.store
    do {
      let value = try await Task.detached(priority: .userInitiated) {
        try store.sharedContexts(contextID: nil, limit: 32, afterContextID: after, expectedCursor: cursor)
      }.value
      guard !Task.isCancelled, showsHistory else { return }
      historyDirectory = value; directoryError = nil
    } catch { directoryError = "История изменилась или недоступна. Откройте новые фрагменты. " + error.localizedDescription }
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

/// Only one addressed history page is retained, including after navigation.
private struct NotebookContextHistoryView: View {
  @Environment(NotebookAppModel.self) private var model
  let contextID: UUID
  let show: (CollaborationReference) -> Void
  @State private var page: SharedContextPage?
  @State private var after: UUID?
  @State private var cursor: String?
  @State private var request = UUID()
  @State private var errorMessage: String?
  @State private var loading = false

  var body: some View {
    List {
      ForEach(page?.entries ?? []) { entry in
        Section(entry.author == .human ? "Вы" : "Агент") {
          if let text = entry.text { Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)).textSelection(.enabled) }
          ForEach(entry.references) { reference in
            Button(reference.label.isEmpty ? model.locationTitle(for: reference) : reference.label) { show(reference) }
          }
        }
      }
      if let errorMessage { Text(errorMessage).accessibilityIdentifier("context-history-error") }
    }
    .accessibilityIdentifier("context-entry-list")
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button { after = nil; cursor = nil; request = UUID() } label: { Text("В начало").frame(minHeight: 44) }
        Spacer()
        if errorMessage == nil, let page, let next = page.nextEntryID {
          Button { after = next; cursor = page.readCursor; request = UUID() } label: { Text("Дальше").frame(minHeight: 44) }
            .accessibilityIdentifier("context-history-next")
        }
      }.disabled(loading).padding(12).background(.regularMaterial)
    }
    .navigationTitle("История фрагмента")
    .task(id: request) {
      loading = true
      defer { loading = false }
      let store = model.store, after = after, cursor = cursor
      do {
        let value = try await Task.detached(priority: .userInitiated) {
          try store.sharedContextPage(contextID: contextID, afterEntryID: after, expectedCursor: cursor, limit: 32)
        }.value
        guard !Task.isCancelled else { return }
        page = value; errorMessage = nil
      } catch { errorMessage = "История изменилась или недоступна. Вернитесь в начало. " + error.localizedDescription }
    }
  }
}

struct NotebookAttentionMarks: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  var body: some View {
    ZStack(alignment:.topLeading) {
      // A retained history entry is not a live indication. The same question
      // owns both its card and its frame, even during delayed SQL publication.
      if let question = model.agentQuestion {
        let entry = model.sharedContexts.first { $0.id == question.contextID }?.previewEntries.first { $0.id == question.entryID }
        ForEach(question.references) { reference in
          if let rect = NotebookAttentionProjection.frame(reference,model:model,presence:presence) {
            mark(rect, human:true, label:"Указано" + (model.referenceStatusLabel(reference).map { " · " + $0 } ?? ""), changed:entry?.requiresReview ?? false)
          }
        }
      }
      if !model.scenePreparationPending, model.collaborationDetailsAreCurrent {
        ForEach(model.collaborationActions.filter { model.pendingAgentHighlights.contains($0.id) && $0.undo == nil }) { action in
          ForEach(model.results(for: action)) { reference in
            if let rect = NotebookAttentionProjection.frame(reference, model: model, presence: presence),
              rect.intersects(CGRect(x: 0, y: 0, width: presence.viewport.x, height: presence.viewport.y)) {
              NotebookAgentPearl(rect: rect) { model.finishAgentHighlight(action.id) }.id(reference.id)
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

/// A short light on the changed material, never a modal surface or a gesture owner.
private struct NotebookAgentPearl: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let rect: CGRect
  let finished: () -> Void
  @State private var visible = false
  var body: some View {
    RoundedRectangle(cornerRadius: 10)
      .strokeBorder(LinearGradient(colors: [.white, Color(red: 0.72, green: 0.85, blue: 0.93),
        Color(red: 0.90, green: 0.78, blue: 0.89), .white], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.5)
      .shadow(color: Color(red: 0.78, green: 0.82, blue: 0.94).opacity(0.65), radius: 7)
      .opacity(visible ? 0.95 : 0)
      .frame(width: max(12, rect.width + 8), height: max(12, rect.height + 8))
      .position(x: rect.midX, y: rect.midY)
      .task {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { visible = true }
        do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.8)) { visible = false }
        do { try await Task.sleep(for: .seconds(0.8)) } catch { return }
        finished()
      }
  }
}
