import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NotebookCore

@MainActor
final class NotebookMacPasteWindow: NSWindowController {
  init(model: NotebookAppModel) {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 380, height: 210),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Вставить"
    window.isReleasedWhenClosed = false
    window.minSize = .init(width: 360, height: 180)
    super.init(window: window)
    // Capture once at the user's command, preserving all representations. Both
    // platforms then use the same clipboard reader and native action executor.
    let providers = Self.providers(from: .general)
    window.contentViewController = NSHostingController(rootView:
      NotebookMacPasteContent(destinations: model.pasteDestinations, providers: providers,
        onComposition: { [weak window] in window?.setContentSize(.init(width: 620, height: 760)) },
        onClose: { [weak self] in self?.close() }).environment(model))
    window.center()
  }
  static func providers(from pasteboard: NSPasteboard) -> [NSItemProvider] {
    (pasteboard.pasteboardItems ?? []).map { item in
      let provider = NSItemProvider()
      let types = NotebookClipboard.types.compactMap { supported in
        item.types.first { UTType($0.rawValue)?.conforms(to: supported) == true }
      }
      for type in Set(types) {
        guard let data = item.data(forType: type) else { continue }
        provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
          completion(data, nil); return nil
        }
      }
      return provider
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func present() {
    showWindow(nil)
    NSApplication.shared.activate()
    window?.makeKeyAndOrderFront(nil)
  }
}

private struct NotebookMacPasteContent: View {
  @Environment(NotebookAppModel.self) private var model
  let destinations: [NotebookPasteDestination]
  let providers: [NSItemProvider]
  let onComposition: () -> Void
  let onClose: () -> Void
  @State private var destinationID: String?
  @State private var content: NotebookClipboard.Content?
  @State private var failure: String?
  @State private var saving = false
  @State private var preparedDestinationID: String?
  private var destination: NotebookPasteDestination? { destinations.first { $0.id == destinationID } ?? destinations.first }

  var body: some View {
    Group {
      if case .composition(let source) = content {
        NotebookTldrawCompositionView(destinations: destinations, initialSource: source, onClose: onClose)
      } else {
        VStack(alignment: .leading, spacing: 16) {
          if destinations.count > 1 {
            Picker("Куда", selection: Binding(get: { destination?.id ?? "" }, set: { destinationID = $0 })) {
              ForEach(destinations) { Text($0.title).tag($0.id) }
            }
          } else if let destination { Text(destination.title).font(.headline) }
          if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
          else if content == nil { ProgressView() }
          else if case .fragment(let fragment) = content {
            Text(fragment.elements.count == 1 ? String(fragment.elements[0].source.prefix(100)) : "Материалов: \(fragment.elements.count)")
              .font(.callout).foregroundStyle(.secondary).lineLimit(2)
          }
          HStack {
            Spacer()
            Button("Вставить") {
              guard case .fragment(let fragment) = content, let destination, preparedDestinationID == destination.id else { return }
              saving = true
              Task {
                if await model.insertClipboardFragment(fragment, at: destination) { onClose() }
                else { failure = "Не удалось сохранить. Попробуйте ещё раз." }
                saving = false
              }
            }.buttonStyle(.borderedProminent).disabled(saving || content == nil || destination == nil || preparedDestinationID != destination?.id)
          }
        }.padding(20).frame(minWidth: 360)
      }
    }
    .background(NotebookChrome.surface)
    .task(id: destination?.id) {
      guard let destination else { failure = "Нет поверхности для вставки."; return }
      do {
        let value = try await NotebookClipboard.read(providers, availableSize: destination.availableSize)
        guard !Task.isCancelled else { return }
        content = value; failure = nil; preparedDestinationID = destination.id
        if case .composition = value { onComposition() }
      } catch { if !Task.isCancelled { failure = error.localizedDescription; content = nil } }
    }
  }
}
