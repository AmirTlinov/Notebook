import Foundation
import Testing
@testable import NotebookCore

@Suite("Element identity queries share the retained source lookup")
struct NotebookElementIdentityLookupTests {
  @Test func repeatedIdentityQueriesAmongOneHundredThousandElementsPreserveAliases() throws {
    // Sparse archives retain implicit field versions without manufacturing
    // 100000 elements' worth of metadata just to exercise a local query.
    struct Archive: Encodable {
      let format = PageDocument.formatVersion
      let id = UUID()
      let size = PageSize(width: 834, height: 1194)
      let drawingData = Data()
      let drawingStamp: VersionStamp
      let agentStamp: VersionStamp
      let elements: [AgentElement]
      let collaboration: CollaborativeContent
    }
    let actor = UUID(), boardID = UUID(), stamp = VersionStamp(counter: 17, actor: actor)
    let identity = VersionStamp(counter: 11, actor: actor)
    let target = "aAAAAAAA-bBbB-CCCC-dddd-EEEEeeeeEEEE"
    let ids = (0..<100_000).map { $0 == 99_999 ? target : "part-\($0)" }
    let elements = ids.map { id in
      AgentElement(id: id, kind: .nativeText, frame: .init(x: 0, y: 0, width: 80, height: 40),
        source: "Body", html: "")
    }
    let metadata = CollaborativeContent(fields: [
      fieldKey(["elements", collaborationIdentity(target), "id"]): .init(stamp: identity, human: true),
      fieldKey(["elements", "absent", "id"]): .init(stamp: identity, human: true),
    ])
    let archive = Archive(drawingStamp: stamp, agentStamp: stamp, elements: elements, collaboration: metadata)
    let page = try JSONDecoder().decode(PageDocument.self, from: JSONEncoder().encode(archive))
    let spatial = ids.map { id in
      SpatialElement(id: id, surface: .board(boardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 80, height: 40), worldOrigin: .zero, source: "Body", stamp: stamp)
    }
    let board = BoardDocument(freeItems: [], stamp: stamp).projecting(placements: [], elements: spatial)
    // Selection already owns these projections before checking its identity fence.
    #expect(page.element(id: target)?.id == target)
    #expect(board.element(id: target)?.id == target)
    let queries = [ids[0], ids[50_000], target, target]
    for (name, lookup) in [("page", page.elementIdentityStamp), ("board", board.elementIdentityStamp)] {
      var samples: [Duration] = [], matches = 0
      for _ in 0..<3 {
        let start = ContinuousClock.now
        for _ in 0..<4 {
          for id in queries {
            let expected = name == "page" && id == target ? identity : stamp
            if lookup(id) == expected { matches += 1 }
          }
        }
        samples.append(start.duration(to: .now))
      }
      #expect(matches == 48)
      print("ELEMENT_IDENTITY_LOOKUP owner=\(name) elements=100000 queries_per_sample=16 samples=\(samples)")
      for alias in [target, target.lowercased(), target.uppercased()] {
        #expect(lookup(alias) == (name == "page" ? identity : stamp))
      }
      #expect(lookup("absent") == nil, "Retained field clocks do not resurrect a removed element")
      #expect(lookup("Part-50000") == nil, "Non-UUID IDs remain case sensitive")
      #expect(lookup("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF") == nil)
    }
  }
}
