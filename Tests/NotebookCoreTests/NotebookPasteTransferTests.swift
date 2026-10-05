import Foundation
import Testing
@testable import NotebookCore

@Suite("Portable paste admission")
struct NotebookPasteTransferTests {
  private let polygon:[SpatialPoint]=[.init(x:0,y:0),.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)]

  private func masked(_ count:Int) -> NotebookPasteFragment {
    let mask=NotebookGraphicMask(operations:(0..<count).map { _ in .init(.intersect,polygon:polygon) })
    let element=AgentElement(id:"masked",kind:.graphic,frame:.init(x:0,y:0,width:120,height:80),
      source:"",html:"",graphic:.init(shape:.rectangle,mask:mask))
    return .init(elements:[element],size:.init(x:120,y:80))
  }

  @Test func maskAdmissionSurvivesWireRoundTripAtTheCurrentFormatBoundary() throws {
    for count in [62,63,64] {
      let decoded=try JSONDecoder().decode(NotebookPasteFragment.self,from:JSONEncoder().encode(masked(count)))
      let copy=try decoded.reidentified()
      #expect(copy.elements[0].graphic?.mask?.operations.count == count)
      #expect(copy.elements[0].id != "masked")
      #expect(try copy.operations(target:.init(kind:.board,id:UUID()),worldOrigin:.zero).count == 1)
    }
    let overflow=masked(65)
    #expect(throws:CollaborationError.self) { try overflow.reidentified() }
    #expect(throws:CollaborationError.self) { try overflow.operations(target:.init(kind:.page,id:UUID())) }
  }

  @Test func missingNonGroupAndCyclicParentsAreRejectedBeforeInsertion() throws {
    func group(_ id:String,_ parent:String?) -> AgentElement {
      .init(id:id,kind:.group,frame:.init(x:0,y:0,width:100,height:100),source:"",html:"",
        parentID:parent,basis:.init(size:.init(x:100,y:100)))
    }
    for elements in [[group("child","missing")],[group("a","b"),group("b","a")]] {
      #expect(throws:CollaborationError.self) {
        try NotebookPasteFragment(elements:elements,size:.init(x:100,y:100)).reidentified()
      }
    }
    let valid=try NotebookPasteFragment(elements:[group("root",nil),group("child","root")],
      size:.init(x:100,y:100)).reidentified()
    #expect(valid.elements[1].parentID == valid.elements[0].id)
  }

  @Test func packageIdentityWithoutItsResourceClosureIsNotPortable() throws {
    let element=AgentElement(id:"program",kind:.web,frame:.init(x:0,y:0,width:100,height:100),
      source:"",html:"",programPackage:String(repeating:"a",count:64))
    let fragment=NotebookPasteFragment(elements:[element],size:.init(x:100,y:100))
    #expect(throws:CollaborationError.self) { try fragment.reidentified() }
  }
}
