import Foundation
import Testing
@testable import NotebookCore

@Suite("Context replies resolve by immutable ID")
struct SharedContextValidationTests {
  private func entry(_ counter: UInt64, actor: UUID, replyTo: UUID? = nil,
    id: UUID = UUID(), text: String = "Ответ") -> SharedContextEntry {
    .init(id: id, author: .human, references: [], replyTo: replyTo, text: text,
      stamp: .init(counter: counter, actor: actor), createdAt: Date(timeIntervalSince1970: 0))
  }

  @Test func failedMergeLeavesTheAcceptedContextUnchanged() throws {
    let actor = UUID(), first = entry(1, actor: actor)
    var context = SharedContext(entries: [first])
    let before = context
    let orphan = entry(2, actor: actor, replyTo: UUID())
    #expect(throws: CollaborationError.self) { try context.merge(.init(id: context.id, entries: [orphan])) }
    #expect(context == before)
    try context.validate()
    let valid = entry(2, actor: actor, replyTo: first.id)
    try context.merge(.init(id: context.id, entries: [valid]))
    #expect(context.entries.map(\.id) == [first.id, valid.id])
  }

  @Test func repeatedIDsInsideOneIncomingPacketAreRejectedWithoutMutation() throws {
    let actor = UUID(), first = entry(1, actor: actor)
    var context = SharedContext(entries: [first])
    let before = context, reply = entry(2, actor: actor, replyTo: first.id)
    #expect(throws: CollaborationError.self) { try context.merge(.init(id: context.id, entries: [reply, reply])) }
    #expect(context == before)
    #expect(throws: CollaborationError.self) { try SharedContext(entries: [first, first]).validate() }
  }

  @Test func partialReplyAndAnExactEchoRetainTheirImmutableEntries() throws {
    let actor = UUID(), first = entry(1, actor: actor)
    var context = SharedContext(entries: [first])
    let reply = entry(2, actor: actor, replyTo: first.id)
    try context.merge(.init(id: context.id, entries: [reply]))
    let accepted = context
    try context.merge(.init(id: context.id, entries: [reply]))
    #expect(context == accepted)
    let conflict = entry(2, actor: actor, replyTo: first.id, id: reply.id, text: "Другая версия")
    #expect(throws: CollaborationError.self) { try context.merge(.init(id: context.id, entries: [conflict])) }
    #expect(context == accepted)
  }

  @Test func replyCausalityUsesCounterNotArrayOrderOrActorTieBreak() throws {
    let first = entry(7, actor: UUID()), later = entry(8, actor: UUID(), replyTo: first.id)
    try SharedContext(entries: [later, first]).validate()
    let simultaneous = entry(7, actor: UUID(), replyTo: first.id)
    #expect(throws: CollaborationError.self) { try SharedContext(entries: [simultaneous, first]).validate() }
    let selfID = UUID(), selfReply = entry(9, actor: UUID(), replyTo: selfID, id: selfID)
    #expect(throws: CollaborationError.self) { try SharedContext(entries: [selfReply]).validate() }
  }

  @Test func invalidContentDoesNotReplaceAcceptedHistory() throws {
    let actor = UUID(), first = entry(1, actor: actor)
    var context = SharedContext(entries: [first])
    let before = context, blank = entry(2, actor: actor, replyTo: first.id, text: " \n\t")
    #expect(throws: CollaborationError.self) { try context.merge(.init(id: context.id, entries: [blank])) }
    #expect(context == before)
  }

  @Test func anUnrepresentableClockCannotEnterOrPoisonTheHistory() throws {
    let actor = UUID(), first = entry(1, actor: actor)
    var context = SharedContext(entries: [first])
    let before = context, invalid = entry(VersionStamp.maximumCounter + 1, actor: actor, replyTo: first.id)
    #expect(throws: CollaborationError.self) { try context.merge(.init(id: context.id, entries: [invalid])) }
    #expect(context == before)
    #expect(throws: CollaborationError.self) { try SharedContext(entries: [invalid]).validate() }
    try context.merge(.init(id: context.id, entries: [entry(2, actor: actor, replyTo: first.id)]))
    #expect(context.entries.count == 2)
  }

  @Test func oneHundredThousandReversedRepliesValidateWithoutSearchingTheArrayPerEntry() throws {
    let actor = UUID()
    var entries: [SharedContextEntry] = []
    entries.reserveCapacity(100_000)
    for counter in 1...100_000 {
      entries.append(entry(UInt64(counter), actor: actor, replyTo: entries.last?.id))
    }
    let context = SharedContext(entries: entries.reversed())
    let clock = ContinuousClock(), start = clock.now
    try context.validate()
    print("CONTEXT_REPLY_SCALE entries=100000 duration=\(start.duration(to: clock.now))")
    #expect(context.entries.count == 100_000)
  }
}
