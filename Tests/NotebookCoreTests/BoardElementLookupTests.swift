import Foundation
import Testing
@testable import NotebookCore

@Suite("Board element lookup follows the immutable board value")
struct BoardElementLookupTests {
  @Test func copiesMutationsAndArchivesNeverShareAStaleLookup() throws {
    let actor=UUID(),boardID=UUID(),stamp=VersionStamp(counter:0,actor:actor)
    let first=SpatialElement(id:"first",surface:.board(boardID),kind:.nativeText,
      frame:.init(x:10,y:20,width:80,height:40),worldOrigin:.zero,source:"First",stamp:stamp)
    let second=SpatialElement(id:"second",surface:.board(boardID),kind:.nativeText,
      frame:.init(x:120,y:20,width:80,height:40),worldOrigin:.zero,source:"Second",stamp:stamp)
    let original=BoardDocument(freeItems:[],elements:[first,second],stamp:stamp)

    #expect(original.element(id:second.id) == second)
    #expect(original.interactionElements(ids:[second.id,first.id,"absent"]) == [first,second])
    var changed=original,updated=second
    let updatedSource=updated.update(source:"Changed",actor:actor)
    #expect(updatedSource)
    let upserted=changed.upsertElement(updated,expected:second.stamp,actor:actor)
    #expect(upserted)
    #expect(changed.element(id:second.id) == updated)
    #expect(original.element(id:second.id) == second)
    #expect(changed != original)

    #expect(changed.removeElements(ids:[first.id],actor:actor) == 1)
    #expect(changed.element(id:first.id) == nil)
    #expect(changed.interactionElements(ids:[second.id,first.id]) == [updated])
    #expect(original.element(id:first.id) == first)

    let decoded=try JSONDecoder().decode(BoardDocument.self,from:JSONEncoder().encode(original))
    #expect(decoded == original)
    #expect(decoded.element(id:first.id) == first)
    #expect(decoded.element(id:second.id) == second)
    #expect(decoded.interactionElements(ids:[second.id,first.id]) == [first,second])
  }

  @Test func aLocalSelectionKeepsPainterOrderAmongOneHundredThousandBodies() {
    let boardID=UUID(),stamp=VersionStamp(counter:0,actor:UUID())
    let elements=(0..<100_000).map { index in
      SpatialElement(id:"part-\(index)",surface:.board(boardID),kind:.nativeText,
        frame:.init(x:Double(index),y:0,width:80,height:40),worldOrigin:.zero,source:"Body",stamp:stamp)
    }
    let board=BoardDocument(freeItems:[],stamp:stamp).projecting(placements:[],elements:elements)
    let ids:Set<String>=["part-99999","part-2","part-50000","absent"]
    #expect(board.interactionElements(ids:ids).map(\.id) == ["part-2","part-50000","part-99999"])
  }
}
