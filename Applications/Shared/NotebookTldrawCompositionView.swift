import SwiftUI
import NotebookCore

/// One native import surface shared by the iPad sheet and Mac utility window.
/// Selection and scale are preparation only; one Insert creates one undo step.
struct NotebookTldrawCompositionView: View {
  @Environment(NotebookAppModel.self) private var model
  let destinations: [NotebookPasteDestination]
  let initialSource: String
  let onClose: () -> Void
  @State private var source = ""
  @State private var namespace = UUID()
  @State private var selected: Set<String>?
  @State private var destinationID: String?
  @State private var scale = 1.0
  @State private var fitted = false
  @State private var fragment: NotebookPasteFragment?
  @State private var failure: String?
  @State private var preparedRequest: Request?
  @State private var preparing = false
  @State private var saving = false
  @State private var showsDetails = false

  private var destination: NotebookPasteDestination? { destinations.first { $0.id == destinationID } ?? destinations.first }
  private var request: Request { .init(source:source,selection:selected?.sorted(),scale:scale,namespace:namespace) }
  private struct Request: Equatable { let source:String; let selection:[String]?; let scale:Double; let namespace:UUID }
  private var selectedIDs: Set<String> { selected ?? Set(fragment?.items.filter { $0.type != "group" }.map(\.id) ?? []) }

  var body: some View {
    VStack(spacing:0) {
      HStack {
        Text("Вставить").font(.headline)
        Spacer()
        Button(action:onClose) { Image(systemName:"xmark").frame(width:44,height:44).contentShape(Rectangle()) }
          .buttonStyle(.plain).accessibilityLabel("Закрыть вставку").disabled(saving)
      }.padding(.horizontal,20).padding(.top,12)
      Divider()
      ScrollView {
        VStack(alignment:.leading,spacing:16) {
          if destinations.count > 1 {
            Picker("Куда",selection:Binding(get:{destination?.id ?? ""},set:{destinationID=$0})) {
              ForEach(destinations) { Text($0.title).tag($0.id) }
            }.accessibilityIdentifier("paste-destination")
          } else if let destination { Label(destination.title,systemImage:destination.target.kind == .page ? "doc" : "rectangle.3.group").font(.subheadline) }
          if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("paste-error") }
          if let fragment {
            Group {
              if fragment.canInsert { NotebookTldrawPreview(fragment:fragment) }
              else {
                VStack(spacing:10) {
                  Image(systemName:"square.on.square").font(.title2)
                  Text(selectedIDs.isEmpty ? "Выберите элементы для вставки" : "Снимите выбор неподдерживаемых элементов")
                    .font(.subheadline).multilineTextAlignment(.center)
                }.foregroundStyle(.secondary).frame(maxWidth:.infinity)
              }
            }.frame(height:220)
              .background(NotebookChrome.surface,in:RoundedRectangle(cornerRadius:12))
              .accessibilityIdentifier("tldraw-preview")
            HStack {
              Text("Элементы").font(.headline)
              Spacer()
              Button(selectedIDs.isEmpty ? "Выбрать все" : "Снять выбор") {
                selected = selectedIDs.isEmpty ? Set(fragment.items.filter{$0.type != "group"}.map(\.id)) : []
              }.font(.subheadline)
            }
            LazyVStack(spacing:0) {
              ForEach(fragment.items.filter{$0.type != "group"}) { item in
                Button { var value=selectedIDs; if !value.insert(item.id).inserted { value.remove(item.id) }; selected=value } label: {
                  HStack(spacing:10) {
                    Image(systemName:selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selectedIDs.contains(item.id) ? Color.accentColor : .secondary)
                    VStack(alignment:.leading,spacing:2) {
                      Text(item.label).lineLimit(2).foregroundStyle(.primary)
                      Text(item.type).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if fragment.diagnostics.contains(where:{$0.sourceID == item.id && $0.severity == .error}) {
                      Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange)
                    }
                  }.frame(minHeight:44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("tldraw-item-"+item.id)
              }
            }
            HStack {
              Text("Масштаб").font(.subheadline)
              Slider(value:$scale,in:0.01...3,step:0.01).accessibilityIdentifier("tldraw-scale")
              Text(scale,format:.percent.precision(.fractionLength(0))).monospacedDigit().frame(width:52)
              if let destination {
                Button("Уместить") { scale = max(0.01,min(3,scale * min(destination.availableSize.x*0.75/max(1,fragment.size.x),destination.availableSize.y*0.75/max(1,fragment.size.y)))) }
              }
            }
            let errors = fragment.diagnostics.filter{$0.severity == .error}
            ForEach(Array(errors.enumerated()),id:\.offset) { _,message in
              Label(message.message,systemImage:"exclamationmark.triangle").font(.subheadline).foregroundStyle(.red)
            }
            let warnings = fragment.diagnostics.filter{$0.severity == .warning}
            if !warnings.isEmpty {
              DisclosureGroup("Адаптация оформления (\(warnings.count))",isExpanded:$showsDetails) {
                ForEach(Array(warnings.enumerated()),id:\.offset) { _,message in Text(message.message).font(.caption).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,3) }
              }.font(.subheadline)
            }
          }
        }.padding(20)
      }.disabled(saving)
      Divider()
      HStack {
        if preparing || saving { ProgressView().controlSize(.small) }
        Text(saving ? "Сохраняем локально…" : preparing ? "Читаем фрагмент…" : "Одна вставка — одна отмена")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Вставить\(fragment?.canInsert == true ? " (\(fragment!.elements.count))" : "")") {
          guard let fragment, let destination else { return }
          saving = true
          Task {
            if await model.insertClipboardFragment(fragment,at:destination) { onClose() }
            else { failure = "Не удалось сохранить. Фрагмент остаётся здесь; попробуйте ещё раз." }
            saving = false
          }
        }.buttonStyle(.borderedProminent).disabled(preparing || saving || preparedRequest != request || fragment?.canInsert != true || destination == nil)
          .accessibilityIdentifier("paste-insert")
      }.padding(20)
    }
    .frame(minWidth:360,idealWidth:620,minHeight:420,idealHeight:760)
    .background(NotebookChrome.surface)
    .interactiveDismissDisabled(saving)
    .onAppear { if source.isEmpty { source=initialSource } }
    .task(id:request) { await prepare(request) }
  }

  private func prepare(_ request:Request) async {
    guard !request.source.isEmpty else { return }
    preparing=true; failure=nil
    let task = Task.detached(priority:.userInitiated) {
      try NotebookTldrawImport.prepare(source:request.source,selectedIDs:request.selection,namespace:request.namespace,scale:request.scale)
    }
    do {
      let value = try await withTaskCancellationHandler { try await task.value } onCancel:{ task.cancel() }
      guard !Task.isCancelled else { return }
      if !fitted, value.canInsert, let destination {
        fitted=true
        let fit=min(1,min(destination.availableSize.x*0.75/max(1,value.size.x),destination.availableSize.y*0.75/max(1,value.size.y)))
        if fit < 1 { scale=max(0.01,fit); return }
      }
      fragment=value; preparedRequest=request; preparing=false
    } catch {
      guard !Task.isCancelled else { return }
      failure=error.localizedDescription; fragment=nil; preparedRequest=nil; preparing=false
    }
  }
}

private struct NotebookTldrawPreview: View {
  let fragment: NotebookPasteFragment
  var body: some View {
    GeometryReader { geometry in
      let scale = min((geometry.size.width-32)/max(1,fragment.size.x),(geometry.size.height-32)/max(1,fragment.size.y))
      let surface=SurfaceID.page(UUID(uuidString:"00000000-0000-0000-0000-000000000001")!)
      let graph=NotebookGraphicGraph(fragment.elements.compactMap { e in e.graphic.map { .init(id:e.id,graphic:$0,frame:e.frame,surface:surface,shown:true) } })
      ZStack(alignment:.topLeading) {
        ForEach(fragment.elements,id:\.id) { e in
          if let graphic=e.graphic,let layout=graph.resolve(e.id).layout {
            NotebookGraphicView(graphic:graphic,layout:layout)
              .frame(width:layout.frame.width,height:layout.frame.height)
              .position(x:layout.frame.x+layout.frame.width/2,y:layout.frame.y+layout.frame.height/2)
          } else {
            // Clipboard HTML is never executed by the native text preview.
            Text((try? AttributedString(markdown:e.source)) ?? AttributedString(e.source)).font(.system(size:24))
              .frame(width:e.frame.width,height:e.frame.height,alignment:.topLeading)
              .position(x:e.frame.x+e.frame.width/2,y:e.frame.y+e.frame.height/2)
          }
        }
      }.frame(width:fragment.size.x,height:fragment.size.y)
        .scaleEffect(scale)
        .frame(width:geometry.size.width,height:geometry.size.height)
        .clipped()
    }.accessibilityLabel("Предпросмотр выбранного фрагмента")
  }
}
