import SwiftUI
import UniformTypeIdentifiers
import NotebookCore

/// Only the user's paste gesture reads the clipboard. HTML is preferred because
/// tldraw's plain-text representation contains labels, not editable structure.
@MainActor
enum NotebookTldrawPaste {
  static let types: [UTType] = [.html,.json,.plainText]
  static func source(_ providers: [NSItemProvider]) async throws -> String {
    for type in types {
      guard let provider = providers.first(where:{$0.hasItemConformingToTypeIdentifier(type.identifier)}) else { continue }
      let data: Data = try await withCheckedThrowingContinuation { continuation in
        provider.loadDataRepresentation(forTypeIdentifier:type.identifier) { data,error in
          if let error { continuation.resume(throwing:error) }
          else if let data { continuation.resume(returning:data) }
          else { continuation.resume(throwing:CollaborationError("invalid_tldraw","Буфер пуст.")) }
        }
      }
      guard data.count <= 1_048_576, let source = String(data:data,encoding:.utf8) else {
        throw CollaborationError("invalid_tldraw","Фрагмент слишком большой или не содержит UTF-8. Скопируйте меньшую часть схемы.")
      }
      return source
    }
    throw CollaborationError("invalid_tldraw","Сначала скопируйте элементы в tldraw.")
  }
}

/// One native import surface shared by the iPad sheet and Mac utility window.
/// Selection and scale are preparation only; one Insert creates one undo step.
struct NotebookTldrawPasteView: View {
  @Environment(NotebookAppModel.self) private var model
  let destinations: [NotebookTldrawDestination]
  var initialSource: String? = nil
  let onClose: () -> Void
  @State private var source = ""
  @State private var namespace = UUID()
  @State private var selected: Set<String>?
  @State private var destinationID: String?
  @State private var scale = 1.0
  @State private var fitted = false
  @State private var fragment: NotebookTldrawImport.Fragment?
  @State private var failure: String?
  @State private var preparedRequest: Request?
  @State private var preparing = false
  @State private var saving = false
  @State private var showsDetails = false
  @State private var pasteTask: Task<Void,Never>?

  private var destination: NotebookTldrawDestination? { destinations.first { $0.id == destinationID } ?? destinations.first }
  private var request: Request { .init(source:source,selection:selected?.sorted(),scale:scale,namespace:namespace) }
  private struct Request: Equatable { let source:String; let selection:[String]?; let scale:Double; let namespace:UUID }
  private var selectedIDs: Set<String> { selected ?? Set(fragment?.items.filter { $0.type != "group" }.map(\.id) ?? []) }

  var body: some View {
    VStack(spacing:0) {
      HStack {
        VStack(alignment:.leading,spacing:4) {
          Text("Вставить из tldraw").font(.headline)
          Text("Отдельные объекты, не картинка").font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Button(action:onClose) { Image(systemName:"xmark").frame(width:44,height:44).contentShape(Rectangle()) }
          .buttonStyle(.plain).accessibilityLabel("Закрыть вставку").disabled(saving)
      }.padding(.horizontal,20).padding(.top,12)
      Divider()
      ScrollView {
        VStack(alignment:.leading,spacing:16) {
          HStack {
            PasteButton(supportedContentTypes:NotebookTldrawPaste.types, payloadAction:paste)
              .labelStyle(.titleAndIcon).accessibilityIdentifier("tldraw-paste")
            Text(source.isEmpty ? "Скопируйте нужные элементы в tldraw, затем вставьте здесь." : "Вставить другой фрагмент")
              .font(.subheadline).foregroundStyle(.secondary)
          }
          if destinations.count > 1 {
            Picker("Куда",selection:Binding(get:{destination?.id ?? ""},set:{destinationID=$0})) {
              ForEach(destinations) { Text($0.title).tag($0.id) }
            }.accessibilityIdentifier("tldraw-destination")
          } else if let destination { Label(destination.title,systemImage:destination.target.kind == .page ? "doc" : "rectangle.3.group").font(.subheadline) }
          if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("tldraw-error") }
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
            if await model.insertTldraw(fragment,at:destination) { onClose() }
            else { failure = "Не удалось сохранить. Фрагмент остаётся здесь; попробуйте ещё раз." }
            saving = false
          }
        }.buttonStyle(.borderedProminent).disabled(preparing || saving || preparedRequest != request || fragment?.canInsert != true || destination == nil)
          .accessibilityIdentifier("tldraw-insert")
      }.padding(20)
    }
    .frame(minWidth:360,idealWidth:620,minHeight:420,idealHeight:760)
    .background(NotebookChrome.surface)
    .interactiveDismissDisabled(saving)
    .onAppear { if source.isEmpty, let initialSource { source=initialSource } }
    .task(id:request) { await prepare(request) }
    .onDisappear { pasteTask?.cancel() }
  }

  private func paste(_ providers:[NSItemProvider]) {
    pasteTask?.cancel()
    pasteTask = Task {
      do {
        let value = try await NotebookTldrawPaste.source(providers)
        guard !Task.isCancelled else { return }
        namespace=UUID(); selected=nil; scale=1; fitted=false; fragment=nil; failure=nil; source=value
      } catch { failure=error.localizedDescription }
    }
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
  let fragment: NotebookTldrawImport.Fragment
  var body: some View {
    Canvas { context,size in
      let scale = min((size.width-32)/max(1,fragment.size.x),(size.height-32)/max(1,fragment.size.y))
      var canvas=context
      canvas.translateBy(x:(size.width-fragment.size.x*scale)/2,y:(size.height-fragment.size.y*scale)/2)
      canvas.scaleBy(x:scale,y:scale)
      let surface=SurfaceID.page(UUID(uuidString:"00000000-0000-0000-0000-000000000001")!)
      let graph=NotebookGraphicGraph(fragment.elements.compactMap { e in e.graphic.map { .init(id:e.id,graphic:$0,frame:e.frame,surface:surface,shown:true) } })
      for e in fragment.elements {
        var layer=canvas
        if let graphic=e.graphic, let layout=graph.resolve(e.id).layout {
          layer.translateBy(x:layout.frame.x,y:layout.frame.y)
          NotebookGraphicView.paint(graphic,layout:layout,in:layer,size:.init(width:layout.frame.width,height:layout.frame.height))
        } else {
          // Native text preview is deliberately not a browser executing clipboard HTML.
          layer.draw(Text((try? AttributedString(markdown:e.source)) ?? AttributedString(e.source)).font(.system(size:24)),in:.init(x:e.frame.x,y:e.frame.y,width:e.frame.width,height:e.frame.height))
        }
      }
    }.accessibilityLabel("Предпросмотр выбранного фрагмента")
  }
}
