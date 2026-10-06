#if os(iOS)
import SwiftUI
import UIKit
import NotebookCore

/// Opening actions captures a context. Its paste gesture shares the workspace
/// menu owner with selection/canvas menus and retains its physical destination.
struct NotebookActionsMenu: UIViewRepresentable {
  let destination: NotebookPasteDestination
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.notebookContextMenus) private var contextMenus
  func makeUIView(context: Context) -> UIButton { NotebookActionsButton(frame:.zero) }
  func updateUIView(_ view: UIButton, context: Context) {
    guard let button=view as? NotebookActionsButton else { return }
    if button.presentationOwner !== contextMenus {
      button.presentationOwner?.detachContentAnchor(button)
      button.presentationOwner=contextMenus
    }
    button.isEnabled=contextMenus != nil
    button.open={ [weak button,weak contextMenus,weak model,destination] in
      guard let button,let contextMenus,let model else { return }
      contextMenus.presentContent(in:model,from:button) { intent in
        NotebookActionsContent(destination:destination,contextMenus:contextMenus,presentationIntent:intent)
          .environment(model)
      }
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
    .init(width:NotebookChrome.controlSize,height:NotebookChrome.controlSize)
  }
  static func dismantleUIView(_ view: UIButton, coordinator: ()) {
    guard let button=view as? NotebookActionsButton else { return }
    button.presentationOwner?.detachContentAnchor(button)
    button.presentationOwner=nil;button.open=nil
  }
}

/// The button carries only its native anchor. Menu identity, dismissal and its
/// selected appearance belong to the workspace presentation owner.
private final class NotebookActionsButton: UIButton {
  weak var presentationOwner: NotebookContextMenus?
  var open: (() -> Void)?
  override init(frame: CGRect) {
    super.init(frame:frame)
    var configuration=UIButton.Configuration.plain()
    configuration.image=UIImage(systemName:"wrench")
    configuration.preferredSymbolConfigurationForImage = .init(pointSize:NotebookChrome.iconSize,weight:.regular)
    configuration.baseForegroundColor = .label
    configuration.contentInsets = .zero
    configuration.background.backgroundInsets = .init(top:5,leading:5,bottom:5,trailing:5)
    configuration.background.cornerRadius=(NotebookChrome.controlSize-10)/2
    self.configuration=configuration
    configurationUpdateHandler={ button in
      var configuration=button.configuration
      configuration?.background.backgroundColor=button.isSelected ? UIColor(NotebookChrome.selectionSurface) : .clear
      button.configuration=configuration
    }
    accessibilityLabel="Действия";accessibilityIdentifier="notebook-actions-open"
    addAction(UIAction { [weak self] _ in self?.open?() },for:.touchUpInside)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct NotebookActionsContent: View {
  let destination: NotebookPasteDestination
  let contextMenus: NotebookContextMenus
  let presentationIntent: NotebookContextMenus.PresentationIntent
  var onClose: (() -> Void)? = nil
  @Environment(NotebookAppModel.self) private var model
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
    onClose?()
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
  }
}
#endif
