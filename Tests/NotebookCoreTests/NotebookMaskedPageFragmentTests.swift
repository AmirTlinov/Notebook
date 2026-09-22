import Foundation
import Testing
@testable import NotebookCore

@Suite struct NotebookMaskedPageFragmentTests {
  @Test func onlyVisibleMaterialMayCrossAnOversizedSourceFrame() throws {
    let size=PageSize(width:834,height:1194)
    let source=PageRect(x:49.75,y:143.34,width:784.25,height:1050.66)
    let moved=PageRect(x:source.x+110,y:source.y+70,width:source.width,height:source.height)
    let mask=NotebookGraphicMask().appending(.intersect,polygon:[
      .init(x:0.28,y:0.04),.init(x:0.53,y:0.04),.init(x:0.53,y:0.19),.init(x:0.28,y:0.19)])
    let graphic=NotebookGraphic(shape:.rectangle,mask:mask)
    let fragment=AgentElement(id:"fragment",kind:.graphic,frame:moved,source:"",html:"",
      graphic:graphic,basis:.init(size:.init(x:source.width,y:source.height)))
    #expect(!moved.isContained(in:size))
    #expect(PageDocument.elementsAreValid([fragment],in:size))
    let encoded=try JSONEncoder().encode(PageDocument(size:size,actor:UUID(),elements:[fragment]))
    let reopened=try JSONDecoder().decode(PageDocument.self,from:encoded)
    #expect(reopened.elements == [fragment])

    let unmasked=AgentElement(id:"fragment",kind:.graphic,frame:moved,source:"",html:"",
      graphic:.init(shape:.rectangle),basis:fragment.basis)
    #expect(!PageDocument.elementsAreValid([unmasked],in:size))
    let subtractOnly=AgentElement(id:"fragment",kind:.graphic,frame:moved,source:"",html:"",
      graphic:.init(shape:.rectangle,mask:NotebookGraphicMask().appending(.subtract,
        polygon:[.init(x:0,y:0),.init(x:0.5,y:0),.init(x:0.5,y:1),.init(x:0,y:1)])),basis:fragment.basis)
    #expect(!PageDocument.elementsAreValid([subtractOnly],in:size))
  }
}
