import NotebookCore
import SwiftUI

struct NotebookCollaborationView: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var showsHistory = false
  @State private var pendingShow: CollaborationReference?
  var body: some View {
    VStack(alignment:.leading,spacing:8) {
      if model.isPointing {
        Label("Укажите фрагмент · протяните для области",systemImage:"hand.point.up.left")
          .font(.callout).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
      }
      if model.showsCollaborationNotice, let attention = model.sharedAttention.last(where: { $0.author == .agent }), let reference = attention.reference {
        HStack(alignment:.top,spacing:10) {
          Image(systemName:"quote.bubble").accessibilityHidden(true)
          VStack(alignment:.leading,spacing:4) {
            Text("Понимание агента").font(.caption.weight(.semibold))
            Text(reference.label).font(.callout).lineLimit(4)
            if model.referenceChanged(reference) { Text("Фрагмент изменился · рассмотрим заново").font(.caption).foregroundStyle(.secondary) }
          }
          Button("Показать") { model.requestShow(reference) }.buttonStyle(.borderless)
        }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
      }
      if model.showsCollaborationNotice, let latest = model.collaborationActions.first {
        HStack(spacing:12) {
          Button { showsHistory = true } label: {
            VStack(alignment:.leading,spacing:3) {
              Text(latest.undo == nil ? "Ход агента" : "Ход отменён").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              Text(latest.action.summary).font(.callout).lineLimit(2)
              if model.continuations(for:latest).contains(where: { $0.author == .human }) {
                Text("Продолжено вами").font(.caption).foregroundStyle(.secondary)
              }
            }.frame(maxWidth:.infinity,alignment:.leading)
          }.buttonStyle(.plain).accessibilityIdentifier("collaboration-history")
          if let reference = model.results(for:latest).first {
            Button("Показать") { model.requestShow(reference) }.accessibilityIdentifier("collaboration-show")
          }
          if latest.undo == nil {
            Button("Отменить") { model.undoCollaboration(latest.id) }.accessibilityIdentifier("collaboration-undo")
          }
          Button { model.dismissCollaborationNotice() } label: { Image(systemName:"xmark") }
            .accessibilityLabel("Скрыть уведомление").accessibilityIdentifier("collaboration-dismiss")
        }.buttonStyle(.borderless).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
      }
      if !model.showsCollaborationNotice, !model.collaborationActions.isEmpty || model.sharedAttention.contains(where: { $0.author == .agent && $0.reference != nil }) {
        Button { showsHistory = true } label: { Label("История",systemImage:"clock.arrow.circlepath") }
          .buttonStyle(.plain).font(.callout).padding(10).background(.regularMaterial,in:Capsule())
          .accessibilityIdentifier("collaboration-history")
      }
    }
    .frame(maxWidth:520,alignment:.leading)
    .sheet(isPresented:$showsHistory, onDismiss: {
      if let reference = pendingShow { pendingShow = nil; model.requestShow(reference) }
    }) {
      NavigationStack {
        List {
          if let reference = model.sharedAttention.last(where: { $0.author == .agent })?.reference {
            Section("Понимание агента") {
              Text(reference.label)
              Button("Показать фрагмент") { pendingShow = reference; showsHistory = false }
            }
          }
          ForEach(model.collaborationActions) { action in
          VStack(alignment:.leading,spacing:10) {
            Text(action.action.summary).font(.headline)
            let continued = model.continuations(for:action)
            if !continued.isEmpty {
              ForEach(Array(Set(continued.map(continuationLabel))).sorted(),id:\.self) { label in
                Text(label)
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            if let undo = action.undo {
              Text(undo.preserved.isEmpty ? "Отменено" : "Отменено · ваши доработки сохранены (\(undo.preserved.count))")
                .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(model.results(for:action).enumerated()),id:\.element.id) { index,reference in
              Button { pendingShow = reference; showsHistory = false } label: {
                Label("Показать результат \(index+1) · \(reference.elementID ?? model.referenceTitle(reference))",systemImage:"scope")
              }
            }
            if action.undo == nil { Button("Отменить этот ход") { model.undoCollaboration(action.id) } }
          }.padding(.vertical,6)
          }
        }
        .buttonStyle(.borderless)
        .navigationTitle("Совместные ходы")
        .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Готово") { showsHistory = false } } }
      }.frame(minWidth:360,minHeight:400)
    }
  }

  private func continuationLabel(_ field: CollaborationContinuation) -> String {
    let owner = field.author == .human ? "Ваша доработка" : field.author == .removed ? "Удалено позднее" : "Продолжено агентом"
    let names = field.path.compactMap { if case .field(let name) = $0 { return name }; return nil }
    let aspect = names.contains("frame") || names.contains("center") ? "положение" : names.contains("css") ? "оформление" : names.contains("state") || names.contains("records") ? "состояние" : "содержание"
    return "\(owner) · \(field.elementID ?? "предмет") · \(aspect)"
  }
}

struct NotebookAttentionMarks: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  var body: some View {
    ZStack(alignment:.topLeading) {
      ForEach(model.sharedAttention,id:\.author) { attention in
        if (attention.author == .human || model.showsCollaborationNotice), let reference = attention.reference, let rect = NotebookAttentionProjection.frame(reference,model:model,presence:presence) {
          mark(rect, human:attention.author == .human, label:attention.author == .human ? "Указано" : "Понимание агента", changed:model.referenceChanged(reference))
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
