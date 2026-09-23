import Foundation
import Testing
@testable import NotebookCore

@Suite("Structured tldraw import")
struct NotebookTldrawImportTests {
  static let namespace = UUID(uuidString:"A483C0B4-A671-43B5-9DD8-B74109D59272")!
  static func shape(_ id: String, _ type: String = "geo", x: Double = 0, y: Double = 0,
    parent: String = "page:root", rotation: Double = 0, props: [String:JSONValue] = [:]) -> JSONValue {
    var defaults: [String:JSONValue] = ["geo":.string("rectangle"),"w":.number(100),"h":.number(80),
      "color":.string("black"),"size":.string("m"),"dash":.string("solid"),"fill":.string("none")]
    defaults.merge(props) { _,new in new }
    return .object(["id":.string("shape:"+id),"type":.string(type),"parentId":.string(parent),"index":.string("a"+id),
      "x":.number(x),"y":.number(y),"rotation":.number(rotation),"props":.object(defaults)])
  }
  static func content(_ shapes: [JSONValue], bindings: [JSONValue] = []) throws -> String {
    let value = JSONValue.object(["schema":.object(["schemaVersion":.number(2),"sequences":.object([:])]),
      "shapes":.array(shapes),"bindings":.array(bindings)])
    return String(decoding:try JSONEncoder().encode(value),as:UTF8.self)
  }
  static func prepare(_ shapes:[JSONValue], selected:[String]? = nil, bindings:[JSONValue] = [], scale:Double = 1) throws -> NotebookPasteFragment {
    try NotebookTldrawImport.prepare(source:content(shapes,bindings:bindings),selectedIDs:selected,namespace:namespace,scale:scale)
  }
  static var diagram: [JSONValue] {
    [shape("a"),shape("b",x:300),shape("c","arrow",x:100,y:40,props:["start":.object(["x":.number(0),"y":.number(0)]),"end":.object(["x":.number(200),"y":.number(0)]),"arrowheadEnd":.string("arrow")])]
  }
  static var bindings: [JSONValue] {
    [("a","start",1.0),("b","end",0.0)].map { id,terminal,x in .object([
      "id":.string("binding:"+id),"type":.string("arrow"),"fromId":.string("shape:c"),"toId":.string("shape:"+id),
      "props":.object(["terminal":.string(terminal),"normalizedAnchor":.object(["x":.number(x),"y":.number(0.5)]),"isExact":.bool(true),"isPrecise":.bool(true)])]) }
  }

  @Test func clipboardWireFormats() throws {
    let expected = try NotebookTldrawImport.prepare(source:Self.wireJSON,namespace:Self.namespace)
    let v3 = "<meta charset='utf-8'><div data-tldraw>" + "{\"type\":\"application/tldraw\",\"kind\":\"content\",\"version\":3,\"data\":{\"assets\":[],\"otherCompressed\":\""+Self.wireCompressed+"\"}}</div>"
    let v2 = "{\"type\":\"application/tldraw\",\"kind\":\"content\",\"version\":2,\"data\":"+Self.wireJSON+"}"
    for source in [v3,v3.replacingOccurrences(of:"data-tldraw>",with:"data-tldraw=\"\">"),v3.replacingOccurrences(of:"data-tldraw>",with:"data-tldraw=''>"),v2,Self.wireOld] {
      let actual = try NotebookTldrawImport.prepare(source:source,namespace:Self.namespace)
      #expect(actual.elements == expected.elements)
      #expect(actual.elements.first?.graphic?.label == "Привет ✍️ 🪄")
      #expect(actual.canInsert)
    }
  }

  @Test func selectedObjectsAndBindings() throws {
    let first = try Self.prepare(Self.diagram,bindings:Self.bindings)
    let second = try Self.prepare(Self.diagram,bindings:Self.bindings)
    #expect(first.elements == second.elements)
    #expect(first.sourceIDs.count == 3)
    let connection = try #require(first.elements.first { $0.id == first.sourceIDs["shape:c"] }?.graphic?.connection)
    #expect(connection.start.binding?.elementID == first.sourceIDs["shape:a"])
    #expect(connection.end.binding?.elementID == first.sourceIDs["shape:b"])
    let missing = try Self.prepare(Self.diagram,selected:["shape:c"],bindings:Self.bindings)
    #expect(!missing.canInsert && missing.elements.isEmpty)
    #expect(missing.diagnostics.contains { $0.code == "binding_dependency" })
    let subset = try Self.prepare(Self.diagram,selected:["shape:b"])
    #expect(subset.elements.count == 1)
    #expect(subset.elements[0].frame.x == 0)
    let duplicated = try Self.prepare(Self.diagram,bindings:Self.bindings+Self.bindings)
    #expect(!duplicated.canInsert)
  }

  @Test func emptySelectionKeepsTheCatalogueAndCircleRotationKeepsItsTrueBounds() throws {
    let circle=Self.shape("a",rotation:.pi/4,props:["geo":.string("ellipse"),"w":.number(80),"h":.number(80)])
    let empty=try Self.prepare([circle],selected:[])
    #expect(empty.items.count == 1 && !empty.canInsert && empty.elements.isEmpty)
    let selected=try Self.prepare([circle])
    #expect(selected.elements.first?.frame.width == 80)
    #expect(selected.elements.first?.frame.height == 80)
  }

  @Test func unsupportedNeverDisappearsOrBecomesImage() throws {
    let shapes = [Self.shape("a"),Self.shape("image","image")]
    let all = try Self.prepare(shapes)
    #expect(!all.canInsert && all.elements.isEmpty)
    #expect(all.items.count == 2)
    #expect(all.diagnostics.contains { $0.sourceID == "shape:image" && $0.severity == .error })
    let selected = try Self.prepare(shapes,selected:["shape:a"])
    #expect(selected.canInsert && selected.elements.count == 1)
  }

  @Test func groupedRotationAndNativePalette() throws {
    let group = Self.shape("group","group",x:200,y:100,rotation:.pi/2)
    let child = Self.shape("a",x:20,y:30,parent:"shape:group",props:["fill":.string("solid"),"color":.string("orange")])
    let result = try Self.prepare([group,child],scale:2)
    #expect(result.elements.count == 1)
    let e = result.elements[0]
    #expect(abs(e.frame.width-160)<0.001 && abs(e.frame.height-200)<0.001)
    #expect(e.graphic?.vertices?.count == 4)
    #expect(e.graphic?.style.strokeWidth == 7)
    #expect(e.graphic?.style.stroke.red == 225.0/255)
    #expect(e.graphic?.style.fill?.red == 248.0/255)
    #expect(result.diagnostics.contains { $0.code == "group_unpacked" })
  }

  @Test func curvesIncludedInFragmentBoundsAndTextEscaped() throws {
    let curve = Self.shape("c","arrow",props:["start":.object(["x":.number(0),"y":.number(0)]),"end":.object(["x":.number(200),"y":.number(0)]),"bend":.number(80)])
    let prepared = try Self.prepare([curve])
    #expect(prepared.size.y > 79)
    let text = try Self.prepare([Self.shape("text","text",props:["text":.string("<script>evil()</script>\n**hello**")])])
    #expect(!text.elements[0].html.contains("<script>"))
    #expect(text.elements[0].javaScript.isEmpty)
    #expect(text.elements[0].source.contains("\\*\\*hello"))
  }

  @Test func autoSizedTextDoesNotUseTheStoredEightPointPlaceholder() throws {
    let prepared=try Self.prepare([Self.shape("text","text",props:["w":.number(8),"autoSize":.bool(true),"text":.string("A long editable title")])])
    #expect(prepared.elements[0].frame.width > 100)
    #expect(prepared.elements[0].frame.height < 50)
    let wrapped=try Self.prepare([Self.shape("text","text",props:["w":.number(100),"autoSize":.bool(false),"text":.string("A long editable title with more lines")])])
    #expect(wrapped.elements[0].frame.width == 100)
    #expect(wrapped.elements[0].frame.height > 60)
  }

  @Test func boundedAndMalformedInput() throws {
    for input in ["plain text",String(repeating:"x",count:1_048_577),"{\"shapes\":"+String(repeating:"[",count:100)+"}", "<div data-tldraw>broken"] {
      #expect(throws:Error.self) { try NotebookTldrawImport.prepare(source:input,namespace:Self.namespace) }
    }
    #expect(throws:Error.self) { try NotebookTldrawClipboard.decompress("not@base64") }
    let cycle = [Self.shape("a","group",parent:"shape:b"),Self.shape("b","group",parent:"shape:a")]
    #expect(throws:Error.self) { try Self.prepare(cycle,selected:["shape:a"]) }
  }

  @Test(arguments:[false,true]) func atomicInsertionReopenAndUndo(onBoard:Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tldraw-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store = NotebookStore(root:root), actor = UUID()
    let (workspace,_) = try store.loadOrCreate(actor:actor,pageSize:.init(width:834,height:1194))
    _ = try store.loadOrCreateSpatialInk(actor:actor)
    let target = CollaborationTarget(kind:onBoard ? .board : .page,id:onBoard ? workspace.rootBoardID : workspace.selectedPageID!)
    let fragment = try Self.prepare(Self.diagram,bindings:Self.bindings)
    let operations = try fragment.operations(target:target,offset:.init(x:20,y:40),worldOrigin:onBoard ? .zero : nil)
    let action = CollaborationAction(summary:"Вставить из буфера",expected:[.init(target:target,revision:try store.targetContentRevision(target:target))],operations:operations)
    let receipt = try store.applyNativeAction(action,actor:actor)
    #expect(receipt.author == .human)
    let reopened = NotebookStore(root:root)
    func ids() throws -> Set<String> {
      if onBoard { return Set(try reopened.readSceneWindow(boardID:target.id,bounds:.init(origin:.zero,width:1000,height:1000)).boards.first!.board.elements.map(\.id)) }
      return Set(try reopened.loadPage(target.id).elements.map(\.id))
    }
    #expect(try ids().isSuperset(of:fragment.elements.map(\.id)))
    _ = try reopened.undoCollaborationAction(receipt.id,actor:actor)
    #expect(try ids().isDisjoint(with:fragment.elements.map(\.id)))
  }
}

// Wire fixtures generated by upstream lz-string 1.5.0, not this decoder.
private extension NotebookTldrawImportTests {
  static let wireJSON = #"{"schema":{"schemaVersion":2,"sequences":{}},"shapes":[{"id":"shape:unicode","type":"geo","parentId":"page:root","index":"a1","x":20,"y":30,"rotation":0,"props":{"geo":"rectangle","w":120,"h":80,"color":"black","size":"m","dash":"solid","fill":"none","richText":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Привет ✍️ 🪄"}]}]}}}],"bindings":[]}"#
  static let wireCompressed = #"N4IgzgxgFgpgtgQxALlJWiBqMBOYCWA9gHYoBMANODAI4CuMxEMYKwAvu1WFAgA4sUAbVD4AJinC8ByOsXwRCYmCCoAXAJ4DJAcxiFVIPghyM1ASQnIjCPchyFCaw/mLKAHpIQBGQ5+RkAAxUGigAzMEgDmoIakSkyJF8DnysqCB6BtamEDHEOgA2KlQA7ijeQVRQKAAckYoFhDiSAEYFCBAA1oYEAF4q1nCGYgg8kmCEBeKGAGb4BQWSxCTFUQpQACow7s7pmtrWYoQQhorEambCoPsDNji293zVVGcX51cgN5IXO4Y/uyBAPgggAEQQAcIIAmEEArCCAIRAAASAWHJAPB/sMAfBuAEL2QOwALrYzjYqgtVxiVw6NJCHFAA"#
  static let wireOld = #"N4IgLgngDgpiBcICGUoBsCWBjJYMHsA7AejDQBMAnJAdxABoQBrDQ8hELIsGQsBkADcYlAM4FCCAIyNyuJAlCisACxgBbBfCWqNSAGojxRBACZGomAEcArrywxRigL7OLKlI4QBtUBnaIoh6w8DaE2PjkcIyQsBwA5jD4AlBIlLxgAJIBIKmJ8JT4+PyMrFEAHhxIUgKV8KYADIwQCADMTSCFYLgSCB1QhVBO2iCJyYjpWN2E8WjRIHTwUo2MKggAHB1caPiUHABGaEhYTALiAF5wiOoCckEcoviY7IwAZhhoaByERPOU2CoACowcr8EaxK4gcj4LACLh8DI+UAQjipajxahQNaMeE8PhI8DQSE8UECElgkCAfBBAAIggA4QQBMIIBWEEAQiAAAkAsOSAeD/WYA+DcAIXsgZwAXWFrmFjH2ZVY8WG3hFziAA"#
}
