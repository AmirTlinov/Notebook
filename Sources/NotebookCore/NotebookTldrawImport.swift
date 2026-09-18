import Foundation
import CoreGraphics
import CoreText

/// A portable selection, not a second document model or storage owner. The
/// resulting elements go through the existing action/undo/replication executor.
public enum NotebookTldrawImport {
  public struct Diagnostic: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case warning, error }
    public let severity: Severity
    public let code: String
    public let sourceID: String?
    public let message: String
  }
  public struct Item: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let parentID: String?
    public let type: String
    public let label: String
  }
  public struct Fragment: Codable, Sendable {
    public let items: [Item]
    public let selectedIDs: [String]
    public let elements: [AgentElement]
    public let sourceIDs: [String: String]
    public let diagnostics: [Diagnostic]
    public let size: SpatialPoint
    public let canInsert: Bool

    public func operations(target: CollaborationTarget, offset: SpatialPoint = .init(x:0,y:0),
      worldOrigin: WorldPoint? = nil) throws -> [CollaborationOperation] {
      guard canInsert, [.page,.board,.cover].contains(target.kind), offset.x.isFinite, offset.y.isFinite,
        abs(offset.x) <= 1_000_000, abs(offset.y) <= 1_000_000,
        target.kind == .board ? worldOrigin?.isValid == true : worldOrigin == nil else {
        throw CollaborationError("import_not_ready", "Выберите поддерживаемые элементы и точную поверхность вставки.")
      }
      return try elements.map { element in
        var values = try JSONValue.encode(element).object
        values.removeValue(forKey:"id")
        values["frame"] = try .encode(PageRect(x:element.frame.x+offset.x,y:element.frame.y+offset.y,
          width:element.frame.width,height:element.frame.height))
        if let worldOrigin { values["worldOrigin"] = try .encode(worldOrigin) }
        return .init(kind:.insertElement,target:target,id:element.id,values:values)
      }
    }
  }

  public static func prepare(source: String, selectedIDs: [String]? = nil, namespace: UUID,
    scale: Double = 1) throws -> Fragment {
    guard scale.isFinite, (0.01...100).contains(scale) else { throw NotebookTldrawClipboard.failure("Масштаб должен быть от 0.01 до 100.") }
    let content = try NotebookTldrawClipboard.content(source)
    guard content["schema"]?["schemaVersion"] == .number(2), case .object = content["schema"]?["sequences"] else {
      throw NotebookTldrawClipboard.failure("Нужен фрагмент современной версии tldraw (schema 2).")
    }
    if let bindings = content["bindings"], case .array = bindings {} else if content["bindings"] != nil {
      throw NotebookTldrawClipboard.failure("Некорректный список привязок.")
    }
    let shapes = content["shapes"]?.array ?? []
    guard !shapes.isEmpty, shapes.count <= 512, (content["bindings"]?.array.count ?? 0) <= 1024 else {
      throw NotebookTldrawClipboard.failure("Выберите от 1 до 512 элементов схемы.")
    }
    var records: [String:JSONValue] = [:]
    for shape in shapes {
      guard let id = shape["id"]?.string, id.hasPrefix("shape:"), id.utf8.count <= 120,
        records[id] == nil, shape["type"]?.string != nil, case .object = shape["props"] else {
        throw NotebookTldrawClipboard.failure("Некорректные или повторяющиеся ID элементов.")
      }
      records[id] = shape
    }
    let roots = shapes.compactMap { shape -> String? in
      let parent = shape["parentId"]?.string ?? ""
      return records[parent] == nil ? shape["id"]?.string : nil
    }
    let selection = selectedIDs ?? roots
    guard Set(selection).count == selection.count, selection.allSatisfy({records[$0] != nil}) else {
      throw NotebookTldrawClipboard.failure("Выбор должен содержать существующие уникальные ID исходных элементов.")
    }
    var selected = Set(selection)
    for _ in 0..<shapes.count {
      let before = selected.count
      for shape in shapes where selected.contains(shape["parentId"]?.string ?? "") { selected.insert(shape["id"]!.string!) }
      if selected.count == before { break }
    }
    var diagnostics: [Diagnostic] = [.init(severity:.warning,code:"theme",sourceID:nil,
      message:"Цвета переносятся из стандартной светлой палитры tldraw; произвольные темы не входят в буфер.")]
    func note(_ severity: Diagnostic.Severity, _ code: String, _ id: String?, _ message: String) {
      if !diagnostics.contains(where:{$0.code == code && $0.sourceID == id}) {
        diagnostics.append(.init(severity:severity,code:code,sourceID:id,message:message))
      }
    }
    func transform(_ id: String, visited: Set<String> = []) throws -> CGAffineTransform {
      guard visited.count < 64, !visited.contains(id), let record = records[id],
        let x = record["x"]?.tlNumber, let y = record["y"]?.tlNumber,
        let angle = record["rotation"]?.tlNumber, abs(x) <= 1e6, abs(y) <= 1e6, abs(angle) <= 1e6 else {
        throw NotebookTldrawClipboard.failure("Некорректная геометрия или цикл групп: \(id).")
      }
      if let opacity=record["opacity"], opacity != .number(1) { throw NotebookTldrawClipboard.failure("Полупрозрачный объект или группа пока не поддерживается.") }
      let local = CGAffineTransform(rotationAngle:angle).concatenating(.init(translationX:x,y:y))
      if let parent = record["parentId"]?.string, records[parent] != nil {
        guard records[parent]?["type"]?.string == "group" else { throw NotebookTldrawClipboard.failure("Родитель \(parent) не является поддерживаемой группой.") }
        return try local.concatenating(transform(parent,visited:visited.union([id])))
      }
      guard record["parentId"]?.string?.hasPrefix("page:") == true else {
        throw NotebookTldrawClipboard.failure("Не найден родитель элемента \(id). Копируйте выделение целиком через tldraw.")
      }
      return local
    }
    func orderKey(_ id: String, visited: Set<String> = []) throws -> String {
      guard visited.count < 64, !visited.contains(id), let record = records[id] else { throw NotebookTldrawClipboard.failure("Цикл иерархии tldraw.") }
      guard let index=record["index"]?.string, !index.isEmpty, index.utf8.count <= 256 else {
        throw NotebookTldrawClipboard.failure("Некорректный порядок элементов tldraw.")
      }
      if let parent = record["parentId"]?.string, records[parent] != nil {
        return try orderKey(parent,visited:visited.union([id])) + "/" + index
      }
      return index
    }
    let keys: [(String,String)] = try records.keys.map { ($0,try orderKey($0)) }
    let sortedKeys = keys.sorted { a,b in a.1 == b.1 ? a.0 < b.0 : a.1 < b.1 }
    let ordered: [String] = sortedKeys.map { $0.0 }
    let items = ordered.map { id in Item(id:id,parentID:records[id]?["parentId"]?.string.flatMap { records[$0] == nil ? nil : $0 },
      type:records[id]!["type"]!.string!,label:title(records[id]!)) }
    let sourcePages = Set(selected.compactMap { id -> String? in
      var current=id, visited=Set<String>()
      while visited.insert(current).inserted, let parent=records[current]?["parentId"]?.string {
        if parent.hasPrefix("page:") { return parent }
        current=parent
      }
      return nil
    })
    if sourcePages.count > 1 { note(.error,"multiple_pages",nil,"Выберите элементы одной исходной страницы: страницы файла не будут наложены друг на друга.") }
    if selected.contains(where:{records[$0]?["parentId"]?.string?.hasPrefix("shape:") == true}) {
      note(.warning,"group_unpacked",nil,"Группы станут отдельными редактируемыми элементами с сохранением расположения.")
    }
    let ids = Dictionary(uniqueKeysWithValues:selected.map { ($0,NotebookStore.submissionID(namespace,suffix:"tldraw:"+$0).uuidString.lowercased()) })
    var converted: [String:AgentElement] = [:]
    var transforms: [String:CGAffineTransform] = [:]
    for id in ordered where selected.contains(id) {
      try Task.checkCancellation()
      let record = records[id]!, type = record["type"]!.string!
      if type == "group" {
        continue
      }
      do {
        if let supportedVersion = ["geo":12.0,"arrow":8.0,"line":5.0,"text":4.0][type],
          let version = content["schema"]?["sequences"]?["com.tldraw.shape."+type]?.tlNumber,
          version > supportedVersion { throw ImportProblem("new_schema","Эта версия типа «\(type)» новее поддерживаемой. Обновите Notebook.") }
        let t = try transform(id); transforms[id] = t
        if record["isLocked"] == .bool(true) { note(.warning,"unlocked",id,"Вставленная копия будет доступна для редактирования.") }
        let props = record["props"]!
        for key in ["scale","growY","bend","labelPosition"] where props[key] != nil {
          guard props[key]?.tlNumber != nil else { throw ImportProblem("invalid_property","Некорректное число «\(key)».") }
        }
        for key in ["flipX","flipY"] where props[key] != nil {
          guard case .bool = props[key] else { throw ImportProblem("invalid_property","Некорректный флаг «\(key)».") }
        }
        if let opacity=record["opacity"], opacity != .number(1) { throw ImportProblem("opacity","Полупрозрачные объекты пока не поддерживаются.") }
        if let url = props["url"]?.string, !url.isEmpty { throw ImportProblem("url","Ссылка объекта пока не переносится. Уберите её в копии или исключите объект.") }
        let label = try plainText(props["richText"] ?? props["text"] ?? .string(""))
        let style = try style(props)
        let sourceScale = props["scale"]?.tlNumber ?? 1
        guard sourceScale > 0, sourceScale <= 100 else { throw ImportProblem("scale","Неподдерживаемый масштаб исходного объекта.") }
        if props["dash"]?.string == "draw" { note(.warning,"native_style",nil,"Рукописный контур tldraw станет геометрическим; шрифты и подписи используют оформление Notebook.") }
        var graphic: NotebookGraphic?
        var frame: PageRect
        var source = "", html = "", css = ""
        switch type {
        case "geo":
          guard let shape = NotebookGraphic.Shape(rawValue:props["geo"]?.string ?? ""), shape != .connector, shape != .plus,
            let w = props["w"]?.tlNumber, let h = props["h"]?.tlNumber,
            w > 0, h > 0, w <= 1e6, h <= 1e6 else { throw ImportProblem("geo","Этот вид геометрической фигуры пока не поддерживается.") }
          let height = h + (props["growY"]?.tlNumber ?? 0)
          guard height > 0, height <= 1e6 else { throw ImportProblem("geometry","Некорректная высота фигуры.") }
          var g = NotebookGraphic(shape:shape,style:style,label:label)
          if let polygon = NotebookGraphicGeometry.polygon(g) {
            let vertices = polygon.map { p in
              CGPoint(x:(props["flipX"] == .bool(true) ? 1-p.x : p.x)*w,
                y:(props["flipY"] == .bool(true) ? 1-p.y : p.y)*height).applying(t)
            }
            frame = try bounds(vertices)
            g.vertices = vertices.map { q in
              .init(x:min(1,max(0,(q.x-frame.x)/frame.width)),y:min(1,max(0,(q.y-frame.y)/frame.height)))
            }
          } else if abs(w-height) < 0.000001 {
            let center=CGPoint(x:w/2,y:height/2).applying(t)
            frame = .init(x:center.x-w/2,y:center.y-height/2,width:w,height:height)
          } else {
            guard abs(t.b) < 0.000001 || abs(t.a) < 0.000001 else {
              throw ImportProblem("rotated_ellipse","Наклонённый эллипс пока не поддерживается; его форма не будет подменена.")
            }
            frame = try bounds([CGPoint(x:0,y:0),CGPoint(x:w,y:0),CGPoint(x:w,y:height),CGPoint(x:0,y:height)].map{$0.applying(t)})
          }
          graphic = g
        case "arrow", "line":
          let points: [JSONValue]
          if type == "arrow" { points = [props["start"] ?? .null,props["end"] ?? .null] }
          else {
            points = (props["points"]?.object.values.map{$0} ?? []).sorted { ($0["index"]?.string ?? "") < ($1["index"]?.string ?? "") }
            guard points.count == 2 else { throw ImportProblem("multipoint_line","Линия с несколькими вершинами пока не поддерживается.") }
          }
          let p = try points.map { value -> CGPoint in
            guard let x = value["x"]?.tlNumber, let y = value["y"]?.tlNumber, abs(x) <= 1e6, abs(y) <= 1e6 else { throw ImportProblem("endpoint","Некорректный конец линии.") }
            return CGPoint(x:x,y:y).applying(t)
          }
          frame = try bounds(p)
          let bend = props["bend"]?.tlNumber ?? 0
          guard abs(bend) <= 1e6,
            let startHead = NotebookGraphicConnection.Arrowhead(rawValue:props["arrowheadStart"]?.string ?? "none"),
            let endHead = NotebookGraphicConnection.Arrowhead(rawValue:props["arrowheadEnd"]?.string ?? (type == "arrow" ? "arrow" : "none")) else { throw ImportProblem("arrowhead","Неподдерживаемый наконечник стрелки.") }
          let routing: NotebookGraphicConnection.Routing = props["kind"]?.string == "elbow" ? .elbow : bend == 0 ? .straight : .curved
          if routing == .elbow { note(.warning,"elbow_route",id,"Угловая связь будет проложена нативным маршрутизатором Notebook.") }
          graphic = .init(shape:.connector,style:style,label:label,connection:.init(
            start:.init(point:.init(x:p[0].x-frame.x,y:p[0].y-frame.y)),
            end:.init(point:.init(x:p[1].x-frame.x,y:p[1].y-frame.y)),bend:bend,
            startArrowhead:startHead,endArrowhead:endHead,labelPosition:props["labelPosition"]?.tlNumber ?? 0.5,routing:routing))
        case "text":
          guard abs(t.b) < 0.000001, t.a > 0, let width = props["w"]?.tlNumber, width > 0, width <= 1e6 else {
            throw ImportProblem("rotated_text","Наклонённый текст пока не поддерживается.")
          }
          let fontSize = try textSize(props) * sourceScale
          guard let font = CTFontCreateUIFontForLanguage(.system,fontSize,nil) else { throw ImportProblem("font","Системный шрифт недоступен.") }
          let attributes = [NSAttributedString.Key(kCTFontAttributeName as String):font]
          let attributed = NSAttributedString(string:label,attributes:attributes)
          let textWidth: Double
          if props["autoSize"] == .bool(true) {
            textWidth=max(16*sourceScale,(label.components(separatedBy:"\n").map { line in
              ceil(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string:line,attributes:attributes)),nil,nil,nil))+2
            }.max() ?? 16))
          } else { textWidth=max(16*sourceScale,width*sourceScale) }
          let textFrame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed),CFRange(location:0,length:0),
            CGPath(rect:.init(x:0,y:0,width:textWidth,height:1e6),transform:nil),nil)
          guard CTFrameGetVisibleStringRange(textFrame).length == label.utf16.count else { throw ImportProblem("text","Текст слишком велик для одного элемента.") }
          let lines=max(1,CFArrayGetCount(CTFrameGetLines(textFrame))) + (label.hasSuffix("\n") ? 1 : 0)
          frame = .init(x:t.tx,y:t.ty,width:textWidth,height:ceil(Double(lines)*fontSize*1.3)+4)
          source = label.split(separator:"\n",omittingEmptySubsequences:false).map { line in
            String(line).reduce("") { $0 + ("\\`*_{}[]<>()#+-.!|>".contains($1) ? "\\" : "") + String($1) }
          }.joined(separator:"  \n")
          html = "<p>" + escape(label).replacingOccurrences(of:"\n",with:"<br>") + "</p>"
          let color = style.stroke
          let align = ["start":"left","middle":"center","end":"right"][props["textAlign"]?.string ?? "start"] ?? "left"
          css = "body,p{margin:0;padding:0;font-family:system-ui;font-size:\(fontSize*scale)px;line-height:1.3;color:rgb(\(Int(color.red*255)),\(Int(color.green*255)),\(Int(color.blue*255)));text-align:\(align);white-space:pre-wrap}"
          note(.warning,"native_style",nil,"Рукописный контур tldraw станет геометрическим; шрифты и подписи используют оформление Notebook.")
        default: throw ImportProblem("unsupported_type","Тип «\(type)» пока не поддерживается. Можно выбрать другие элементы; этот не будет заменён картинкой.")
        }
        if !label.isEmpty, graphic != nil { note(.warning,"native_style",nil,"Рукописный контур tldraw станет геометрическим; шрифты и подписи используют оформление Notebook.") }
        if var g = graphic {
          g.style.strokeWidth *= sourceScale
          guard g.isValid else { throw ImportProblem("geometry","Геометрия не соответствует нативному объекту Notebook.") }
          graphic = g
        }
        converted[id] = .init(id:ids[id]!,kind:graphic == nil ? .markdown : .graphic,frame:frame,source:source,html:html,css:css,graphic:graphic)
      } catch let problem as ImportProblem { note(.error,problem.code,id,problem.message) }
      catch { note(.error,"invalid_geometry",id,error.localizedDescription) }
    }
    var boundTerminals = Set<String>()
    for binding in content["bindings"]?.array ?? [] {
      guard let from = binding["fromId"]?.string, selected.contains(from) else { continue }
      guard let to=binding["toId"]?.string, selected.contains(to) else {
        note(.error,"binding_dependency",from,"Выберите также связанный узел: привязка не будет молча потеряна."); continue
      }
      guard let destination=converted[to], let targetGraphic=destination.graphic, targetGraphic.shape != .connector else {
        note(.error,"binding_target",from,"Эта связь направлена не на поддерживаемую геометрическую фигуру. Привязки к тексту, группам и вложениям пока не переносятся."); continue
      }
      guard binding["type"]?.string == "arrow", records[from]?["type"]?.string == "arrow",
        let oldTarget = records[to]?["props"], let transform = transforms[to],
        let w = oldTarget["w"]?.tlNumber, let h = oldTarget["h"]?.tlNumber,
        let props = binding["props"], let terminal = props["terminal"]?.string,
        ["start","end"].contains(terminal), let anchor = props["normalizedAnchor"],
        let ax = anchor["x"]?.tlNumber, let ay = anchor["y"]?.tlNumber, (0...1).contains(ax), (0...1).contains(ay),
        let element = converted[from], var g = element.graphic, var connection = g.connection else {
        note(.error,"invalid_binding",from,"Некорректная или неподдерживаемая привязка стрелки."); continue
      }
      guard boundTerminals.insert(from+"/"+terminal).inserted else {
        note(.error,"duplicate_binding",from,"Один конец линии содержит несколько привязок."); continue
      }
      let p = CGPoint(x:ax*w,y:ay*(h+(oldTarget["growY"]?.tlNumber ?? 0))).applying(transform)
      let mapped = NotebookGraphicConnection.Binding(elementID:destination.id,
        normalizedAnchor:.init(x:min(1,max(0,(p.x-destination.frame.x)/destination.frame.width)),y:min(1,max(0,(p.y-destination.frame.y)/destination.frame.height))),
        isExact:props["isExact"] == .bool(true),isPrecise:props["isPrecise"] != .bool(false))
      if terminal == "start" { connection.start.binding = mapped } else { connection.end.binding = mapped }
      g.connection = connection
      converted[from] = .init(id:element.id,kind:element.kind,frame:element.frame,source:element.source,html:element.html,css:element.css,graphic:g)
    }
    // No partially prepared batch escapes when any selected record failed.
    guard !diagnostics.contains(where:{$0.severity == .error}), !converted.isEmpty else {
      return .init(items:items,selectedIDs:selection,elements:[],sourceIDs:[:],diagnostics:diagnostics,size:.init(x:0,y:0),canInsert:false)
    }
    let surface = SurfaceID.page(namespace)
    let graph = NotebookGraphicGraph(converted.values.compactMap { e in
      e.graphic.map { .init(id:e.id,graphic:$0,frame:e.frame,surface:surface,shown:true) }
    })
    let visibleFrames = ordered.compactMap { id -> PageRect? in
      guard let e=converted[id] else { return nil }
      guard e.graphic?.shape == .connector else { return e.frame }
      guard let layout=graph.resolve(e.id).layout else {
        note(.error,"invisible_connection",id,"Связь не имеет видимой геометрии. Исключите её из выбора."); return nil
      }
      return layout.frame
    }
    guard !diagnostics.contains(where:{$0.severity == .error}) else {
      return .init(items:items,selectedIDs:selection,elements:[],sourceIDs:[:],diagnostics:diagnostics,size:.zero,canInsert:false)
    }
    let union = try bounds(visibleFrames.flatMap { f in [CGPoint(x:f.x,y:f.y),CGPoint(x:f.x+f.width,y:f.y+f.height)] })
    guard union.width*scale <= 1e6, union.height*scale <= 1e6 else { throw NotebookTldrawClipboard.failure("Слишком большой фрагмент. Уменьшите масштаб или выбор.") }
    let elements = ordered.compactMap { converted[$0] }.map { e -> AgentElement in
      var graphic = e.graphic
      if var g = graphic {
        g.style.strokeWidth *= scale
        if var c = g.connection {
          c.start.point = .init(x:c.start.point.x*scale,y:c.start.point.y*scale)
          c.end.point = .init(x:c.end.point.x*scale,y:c.end.point.y*scale); c.bend *= scale; g.connection = c
        }
        graphic = g
      }
      return .init(id:e.id,kind:e.kind,frame:.init(x:(e.frame.x-union.x)*scale,y:(e.frame.y-union.y)*scale,
        width:e.frame.width*scale,height:e.frame.height*scale),source:e.source,html:e.html,css:e.css,graphic:graphic)
    }
    guard elements.allSatisfy({ $0.graphic?.isValid != false }) else {
      throw NotebookTldrawClipboard.failure("Геометрия после масштабирования слишком велика. Уменьшите масштаб.")
    }
    return .init(items:items,selectedIDs:selection,elements:elements,sourceIDs:ids.filter { converted[$0.key] != nil },diagnostics:diagnostics,size:.init(x:union.width*scale,y:union.height*scale),canInsert:true)
  }

  private struct ImportProblem: Error { let code: String; let message: String; init(_ code:String,_ message:String) { self.code=code;self.message=message } }
  private static func bounds(_ points: [CGPoint]) throws -> PageRect {
    guard !points.isEmpty, points.allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1e6 && abs($0.y) <= 1e6}) else {
      throw ImportProblem("geometry","Некорректные координаты исходной фигуры.")
    }
    let x = points.map(\.x).min()!, y = points.map(\.y).min()!
    return .init(x:x,y:y,width:max(1,points.map(\.x).max()!-x),height:max(1,points.map(\.y).max()!-y))
  }
  private static func title(_ record: JSONValue) -> String {
    let text = (try? plainText(record["props"]?["richText"] ?? record["props"]?["text"] ?? .string(""))) ?? ""
    return text.isEmpty ? (record["props"]?["geo"]?.string ?? record["type"]?.string ?? "Элемент") : String(text.prefix(100))
  }
  private static func plainText(_ value: JSONValue, depth: Int = 0) throws -> String {
    guard depth <= 32 else { throw ImportProblem("text","Слишком сложная структура текста.") }
    if let string = value.string { guard string.utf16.count <= 100_000 else { throw ImportProblem("text","Слишком длинный текст.") }; return string }
    let type = value["type"]?.string
    guard ["doc","paragraph","text","hardBreak"].contains(type), (value["marks"]?.array ?? []).isEmpty else {
      throw ImportProblem("rich_text","Форматированный текст с нестандартными узлами или начертаниями пока не переносится без потерь.")
    }
    if type == "hardBreak" { return "\n" }
    if type == "text" { return try plainText(value["text"] ?? .string(""),depth:depth+1) }
    let text = try (value["content"]?.array ?? []).map { try plainText($0,depth:depth+1) }.joined(separator:type == "doc" ? "\n" : "")
    guard text.utf16.count <= 100_000 else { throw ImportProblem("text","Слишком длинный текст.") }; return text
  }
  private static func escape(_ s: String) -> String { s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;") }
  private static func textSize(_ p: JSONValue) throws -> Double {
    guard let size = ["s":18.0,"m":24.0,"l":36.0,"xl":44.0][p["size"]?.string ?? "m"] else { throw ImportProblem("style","Неподдерживаемый размер текста.") }; return size
  }
  private static func style(_ p: JSONValue) throws -> NotebookGraphic.Style {
    let palette = ["black":0x1d1d1d,"grey":0x9fa8b2,"light-violet":0xe085f4,"violet":0xae3ec9,"blue":0x4465e9,
      "light-blue":0x4ba1f1,"yellow":0xf1ac4b,"orange":0xe16919,"green":0x099268,"light-green":0x4cb05e,"light-red":0xf87777,"red":0xe03131,"white":0xffffff]
    guard let rgb = palette[p["color"]?.string ?? "black"],
      let width = ["s":1.0,"m":1.75,"l":2.5,"xl":5.0][p["size"]?.string ?? "m"],
      let dash = ["solid":NotebookGraphic.Style.Dash.solid,"draw":.solid,"dashed":.dashed,"dotted":.dotted][p["dash"]?.string ?? "solid"] else { throw ImportProblem("style","Неподдерживаемый цвет или контур.") }
    let color = SpatialInkColor(red:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255)
    let fill = p["fill"]?.string ?? "none"
    guard ["none","solid","semi","fill"].contains(fill) else { throw ImportProblem("fill","Штриховка или градиент заливки пока не поддерживается.") }
    let soft = ["black":0xe8e8e8,"grey":0xeceef0,"light-violet":0xf5eafa,"violet":0xecdcf2,
      "blue":0xdce1f8,"light-blue":0xddedfa,"yellow":0xf9f0e6,"orange":0xf8e2d4,"green":0xd3e9e3,
      "light-green":0xdbf0e0,"light-red":0xf4dadb,"red":0xf4dadb,"white":0xf5f5f5][p["color"]?.string ?? "black"]!
    let solid = SpatialInkColor(red:Double((soft>>16)&255)/255,green:Double((soft>>8)&255)/255,blue:Double(soft&255)/255)
    let filled = fill == "solid" ? solid : fill == "semi" ? SpatialInkColor(red:252.0/255,green:1,blue:254.0/255) : color
    return .init(stroke:color,strokeWidth:width*2,fill:fill == "none" ? nil : filled,dash:dash)
  }
}

private extension JSONValue {
  var tlNumber: Double? { if case .number(let n) = self, n.isFinite { n } else { nil } }
}
