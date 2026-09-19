import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite("Native boolean contours")
struct NotebookVectorPathTests {
  @Test func curvesHolesAndPaintSurviveCodableAndCausalPatch() throws {
    let outer = CGPath(ellipseIn:.init(x:0,y:0,width:200,height:160),transform:nil)
    let hole = CGPath(ellipseIn:.init(x:60,y:50,width:80,height:60),transform:nil)
    let path = NotebookVectorPath(path:outer.subtracting(hole),frame:.init(x:0,y:0,width:200,height:160))
    #expect(path.isValid)
    #expect(path.commands.contains { $0.kind == .curve })
    let graphic = NotebookGraphic(shape:.path,style:.init(strokeWidth:2,fill:.black),path:path)
    #expect(graphic.isValid)
    let decoded = try JSONValue.encode(graphic).decode(NotebookGraphic.self)
    #expect(decoded == graphic)
    let paint = NotebookGraphicGeometry.paintPath(decoded,layout:nil,size:.init(width:202,height:162))
    #expect(paint.contains(.init(x:20,y:80)))
    #expect(!paint.contains(.init(x:101,y:81)))
    let edited = try NotebookGraphic(shape:.ellipse).applying(.object(["shape":.string("path"),"path":try .encode(path)]))
    #expect(edited.path == path)
    #expect(edited.causalPaths.contains(["path"]))
  }
  @Test func invalidCommandsCannotReachThePainter() {
    #expect(!NotebookVectorPath(commands:[.init(kind:.curve,points:[])]).isValid)
    #expect(!NotebookVectorPath(commands:[.init(kind:.move,points:[.zero])]).isValid)
    #expect(!NotebookVectorPath(commands:[]).isValid)
  }
  @Test func mixedSelectionPublishesExactCardAndElementIDs() throws {
    let board = UUID(), item = UUID()
    var value = NotebookSelection(id:UUID(),kind:.elements,surface:.init(kind:.board,id:board),target:.init(kind:.board,id:board),elementIDs:["text"])
    value.itemIDs = [item]
    #expect(value.isValid)
    #expect(try JSONValue.encode(value).decode(NotebookSelection.self) == value)
    value.itemIDs = [item,item]; #expect(!value.isValid)
  }
}
