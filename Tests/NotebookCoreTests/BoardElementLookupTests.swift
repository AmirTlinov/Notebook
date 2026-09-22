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
    #expect(original.element(id:first.id) == first)

    let decoded=try JSONDecoder().decode(BoardDocument.self,from:JSONEncoder().encode(original))
    #expect(decoded == original)
    #expect(decoded.element(id:first.id) == first)
    #expect(decoded.element(id:second.id) == second)
  }
}
