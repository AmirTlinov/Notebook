import Foundation
import Testing
@testable import NotebookCore

@Suite("Native selection clipboard")
struct NotebookPasteFragmentTests {
  @Test func freshIdentitiesKeepGroupsBindingsAndOffsetOnlyRoots() throws {
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:20,y:30,width:400,height:300),source:"",html:"",
      basis:.init(size:.init(x:400,y:300)))
    let child=AgentElement(id:"child",kind:.graphic,frame:.init(x:40,y:50,width:100,height:80),source:"",html:"",
      graphic:.init(shape:.rectangle,sourceInkIDs:[UUID()]),parentID:whole.id)
    let arrow=AgentElement(id:"arrow",kind:.graphic,frame:.init(x:160,y:90,width:120,height:90),source:"",html:"",
      graphic:.init(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:child.id)),
        end:.init(point:.init(x:120,y:90),binding:.init(elementID:"outside")))),parentID:whole.id)
    let original=NotebookPasteFragment(elements:[whole,child,arrow],size:.init(x:400,y:300))
    let copied=try original.reidentified(),another=try original.reidentified()
    #expect(Set(copied.elements.map(\.id)).isDisjoint(with:original.elements.map(\.id)))
    #expect(Set(copied.elements.map(\.id)).isDisjoint(with:another.elements.map(\.id)))
    #expect(copied.elements[1].parentID == copied.elements[0].id)
    #expect(copied.elements[2].graphic?.connection?.start.binding?.elementID == copied.elements[1].id)
    #expect(copied.elements[2].graphic?.connection?.end.binding == nil)
    #expect(copied.elements[1].graphic?.sourceInkIDs.isEmpty == true)
    let target=CollaborationTarget(kind:.board,id:UUID()),origin=WorldPoint(x:40_000,y:-80_000)
    let operations=try copied.operations(target:target,offset:.init(x:100,y:200),worldOrigin:origin)
    #expect(try operations[0].values["frame"]?.decode(PageRect.self) == .init(x:120,y:230,width:400,height:300))
    #expect(try operations[1].values["frame"]?.decode(PageRect.self) == child.frame)
    #expect(try operations[0].values["worldOrigin"]?.decode(WorldPoint.self) == origin)
    #expect(try operations[1].values["worldOrigin"]?.decode(WorldPoint.self) == .zero)
    #expect(original.elements[1].graphic?.sourceInkIDs.isEmpty == false)
  }

  @Test func groupedNativePasteUsesTheExistingAtomicStoreAndUndo() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID(),header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:0,y:0,width:200,height:200),source:"",html:"",basis:.init(size:.init(x:200,y:200)))
    let text=AgentElement(id:"text",kind:.nativeText,frame:.init(x:20,y:30,width:120,height:60),source:"Текст внутри группы",html:"",parentID:whole.id)
    let fragment=try NotebookPasteFragment(elements:[whole,text],size:.init(x:200,y:200)).reidentified()
    let target=CollaborationTarget(kind:.board,id:header.rootBoardID),origin=WorldPoint(x:12_000,y:-24_000)
    let operations=try fragment.operations(target:target,offset:.init(x:40,y:50),worldOrigin:origin)
    let receipt=try store.applyNativeElementEdits(operations,summary:"Вставить группу",
      sources:operations.map { .init(target:target,id:$0.id!) },actor:actor)
    let board=try #require(try store.loadBoard(items:store.loadIndex().items).board(target.id))
    #expect(board.elements.count == 2)
    let pose=try #require(board.graphicGraph().placement(fragment.elements[1].id))
    #expect(pose.origin == origin);#expect(pose.transform.tx == 60);#expect(pose.transform.ty == 80)
    #expect(receipt.receipt.action.operations.count == 2)
  }

  @Test func incompleteOrDuplicateGroupsAreRejectedBeforePaste() {
    let child=AgentElement(id:"child",kind:.nativeText,frame:.init(x:0,y:0,width:100,height:40),source:"text",html:"",parentID:"missing")
    #expect(throws:Error.self) { try NotebookPasteFragment(elements:[child],size:.init(x:100,y:40)).reidentified() }
    #expect(throws:Error.self) { try NotebookPasteFragment(elements:[child,child],size:.init(x:100,y:40)).reidentified() }
  }
}
