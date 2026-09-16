import NotebookCore
import SwiftUI

/// No WebKit, retained program or independent camera. The parent installs the
/// physical frame; this view paints only that object's local content.
struct NotebookGraphicView: View {
  let graphic: NotebookGraphic
  var body: some View {
    Canvas { context, size in
      guard graphic.showsGeometry else { return }
      let inset = min(graphic.style.strokeWidth / 2, min(size.width, size.height) / 2 - 0.01)
      let rect = CGRect(origin: .zero, size: size).insetBy(dx: max(0, inset), dy: max(0, inset))
      let path = Path(ellipseIn: rect)
      if let fill = graphic.style.fill { context.fill(path, with: .color(fill.swiftUIColor)) }
      context.stroke(path, with: .color(graphic.style.stroke.swiftUIColor), lineWidth: graphic.style.strokeWidth)
      if !graphic.label.isEmpty {
        context.draw(Text(graphic.label).font(.system(size: 24)).foregroundStyle(graphic.style.stroke.swiftUIColor),
          at: CGPoint(x: size.width / 2, y: size.height / 2))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(graphic.label.isEmpty ? "Эллипс" : graphic.label)
    .accessibilityAddTraits(.isImage)
  }
}

extension SpatialInkColor {
  var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }
}

struct NotebookGraphicElementView: View {
  @Environment(NotebookAppModel.self) private var model
  let graphic: NotebookGraphic
  let reference: EditableElementReference
  @State private var draft = ""
  @State private var original = ""
  @State private var hasDraft = false
  @FocusState private var focused: Bool

  private var editing: Bool {
    switch (reference, model.interactiveElementFocus) {
    case (.page(let page, let id), .page(let owner, let element)): return page == owner && id == element
    case (.spatial(let board, let id), .board(let owner, let element)): return board == owner && id == element
    default: return false
    }
  }
  var body: some View {
    ZStack {
      NotebookGraphicView(graphic: editing ? unlabelled : graphic)
      if editing {
        TextField("Подпись", text: $draft, axis: .vertical)
          .font(.system(size: 24)).multilineTextAlignment(.center)
          .textFieldStyle(.plain).padding(8).focused($focused)
          .accessibilityIdentifier("graphic-label-editor")
          .onSubmit { finish() }
          .onChange(of: focused) { _, value in if !value { finish() } }
          .onDisappear { finish() }
      }
    }
    .task(id: editing) {
      if editing { original = graphic.label; draft = original; hasDraft = true; focused = true }
    }
    .onChange(of: editing) { _, value in if !value { finish() } }
  }
  private var unlabelled: NotebookGraphic { var value = graphic; value.label = ""; return value }
  private func finish() {
    guard hasDraft else { return }
    hasDraft = false
    model.setGraphicLabel(draft, reference: reference, replacing: original)
    if editing { model.interactiveElementFocus = nil }
  }
}
