#if os(iOS)
import SwiftUI
import NotebookCore

/// Opening actions captures a context. Its paste gesture shares the workspace
/// menu owner with selection/canvas menus and retains its physical destination.
struct NotebookActionsMenu: View {
  let destination: NotebookPasteDestination
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.notebookContextMenus) private var contextMenus
  @State private var opened: Opened?
  private struct Opened: Identifiable {
    let destination: NotebookPasteDestination
    let intent: NotebookContextMenus.PresentationIntent
    var id: UUID { intent.id }
  }
  private var opening: Binding<Opened?> {
    .init(get: { opened }, set: { value in
      if let previous=opened,previous.id != value?.id {
        contextMenus?.finishContentPresentation(previous.intent)
      }
      opened=value
    })
  }

  var body: some View {
    Button {
      guard let contextMenus else { return }
      opened = .init(destination:destination,intent:contextMenus.beginContentPresentation(in:model))
    } label: {
      Image(systemName: "wrench")
        .font(NotebookChrome.iconFont)
        .frame(width: NotebookChrome.controlSize, height: NotebookChrome.controlSize)
        .background {
          Circle().fill(opened == nil ? Color.clear : NotebookChrome.selectionSurface).padding(5)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).foregroundStyle(.primary).disabled(contextMenus == nil)
    .accessibilityLabel("Действия").accessibilityIdentifier("notebook-actions-open")
    .popover(item: opening, arrowEdge: .top) { captured in
      if let contextMenus {
        NotebookActionsContent(destination:captured.destination,contextMenus:contextMenus,
          presentationIntent:captured.intent)
          .environment(model)
          .presentationCompactAdaptation(.popover)
          .presentationBackground(NotebookChrome.surface)
      }
    }
    .onDisappear {
      if let opened { contextMenus?.finishContentPresentation(opened.intent) }
      opened=nil
    }
  }
}

struct NotebookActionsContent: View {
  let destination: NotebookPasteDestination
  @ObservedObject var contextMenus: NotebookContextMenus
  let presentationIntent: NotebookContextMenus.PresentationIntent
  var onClose: (() -> Void)? = nil
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var presentation: Composition?
  @State private var failure: String?
  @State private var loading = false
  private struct Composition: Identifiable {
    let intent: NotebookContextMenus.ClipboardIntent
    let source: String
    var id: UUID { intent.id }
  }
  private func close() {
    guard contextMenus.isCurrent(presentationIntent,in:model) else { return }
    if let onClose { onClose() } else { dismiss() }
    contextMenus.finishContentPresentation(presentationIntent)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      PasteButton(supportedContentTypes: NotebookClipboard.types) { providers in
        guard contextMenus.isCurrent(presentationIntent,in:model) else { return }
        loading=true;failure=nil
        contextMenus.pasteClipboard(providers,at:destination,in:model,presentation:presentationIntent) { intent,outcome in
          loading=false
          switch outcome {
          case .composition(let source): presentation = .init(intent:intent,source:source)
          case .inserted: close()
          case .failed(let message): failure=message
          }
        }
      }
      .labelStyle(.titleAndIcon).tint(Color(white: 0.28)).buttonBorderShape(.capsule)
      .font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .disabled(loading).accessibilityLabel("Вставить").accessibilityIdentifier("clipboard-paste")
      if loading { ProgressView().controlSize(.small).accessibilityLabel("Вставляем") }
      if let failure {
        Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("paste-error")
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 4)
    .frame(width: failure == nil ? 136 : 280).background(NotebookChrome.surface)
    .sheet(item: $presentation) { value in
      NotebookTldrawCompositionView(destinations:[destination],initialSource:value.source,onClose: {
        guard presentation?.id == value.id,contextMenus.isCurrent(value.intent,in:model) else { return }
        presentation=nil
      }).environment(model)
        .onDisappear {
          guard contextMenus.isCurrent(value.intent,in:model) else { return }
          close()
        }
    }
    .onChange(of:contextMenus.isCurrent(presentationIntent,in:model)) { _,current in
      if !current { presentation=nil;dismiss() }
    }
  }
}
#endif
