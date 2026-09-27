import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("File-backed program state keeps admitted reads and causal publication", .serialized)
struct DocumentProgramStateTests {
  private let path = "programs/counter"
  private enum Fault: Error { case injected }

  private func fixture() throws -> DocumentFileFixture {
    try DocumentFileFixture(files: notebookProgramFiles() + [
      .init(id: "program-css", path: path + "/style.css", source: "button { color: black }"),
      .init(id: "section", path: "sections/body.tex", source: "Independent text")])
  }
  private func source(_ f: DocumentFileFixture, id: String = "counter") throws -> DocumentProgramSource {
    try .init(document: f.store.loadDocument(f.id), instanceID: id, path: path)
  }
  private func command(_ journal: inout DocumentStateJournal, source: DocumentProgramSource,
    value: JSONValue, actor: UUID, human: Bool = true) throws -> NotebookDocumentStateCommand {
    let changed = journal.commit(instanceID: source.id, value: value, actor: actor, human: human)
    #expect(changed)
    return .init(documentID: journal.id, record: try #require(journal.records.first { $0.id == source.id }),
      journalStamp: journal.stamp, programPath: source.path, expectedSourceBasis: source.sourceBasis)
  }
  private func committed(_ value: NotebookDocumentStateResult) throws -> NotebookDocumentStatePublication {
    guard case .committed(let publication) = value else {
      Issue.record("Expected an accepted program value, received \(value)"); throw Fault.injected
    }
    return publication
  }

  @Test func absentStateAndCommittedNullHaveDifferentCheckpointRights() throws {
    let f = try fixture(), source = try source(f)
    let initial = try f.store.readDocumentProgram(documentID: f.id, instanceID: source.id, programPath: path)
    #expect(initial.state == .number(0) && initial.stateVersion == nil)
    let accepted = try #require(try f.store.checkpointDocumentState(documentID: f.id, programID: source.id,
      programPath: path, value: .null, sourceBasis: source.sourceBasis, stateVersion: nil, actor: f.actor))
    let read = try f.store.readDocumentProgram(documentID: f.id, instanceID: source.id, programPath: path)
    #expect(read.state == .null && read.stateVersion == accepted.record.valueVersion)
    let decoded = try JSONValue.encode(read).decode(NotebookDocumentProgramRead.self)
    #expect(decoded.state == .null && decoded.stateVersion == read.stateVersion)
    let cursor = try f.store.currentChangeCursor()
    #expect(try f.store.checkpointDocumentState(documentID: f.id, programID: source.id,
      programPath: path, value: .number(2), sourceBasis: source.sourceBasis, stateVersion: nil, actor: f.actor) == nil)
    #expect(try f.store.checkpointDocumentState(documentID: f.id, programID: source.id,
      programPath: path, value: .null, sourceBasis: source.sourceBasis, stateVersion: read.stateVersion, actor: f.actor) == accepted)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test func capturedCheckpointIsIdempotentButCannotAdoptAStateABA() throws {
    let f = try fixture(), source = try source(f)
    var state = try f.store.loadDocumentState(f.id)
    let initial = try command(&state, source: source, value: .number(1), actor: f.actor)
    _ = try f.store.commitDocumentState(initial)
    var captured = state
    let proposal = try command(&captured, source: source, value: .number(4), actor: f.actor)
    let checkpoint = NotebookDocumentStateCommand(documentID: f.id, record: proposal.record,
      journalStamp: proposal.journalStamp, programPath: path, expectedSourceBasis: source.sourceBasis,
      stateCondition: .matching(initial.record.valueVersion))
    let accepted = try f.store.commitDocumentState(checkpoint)
    #expect(try committed(accepted).record == checkpoint.record)
    let cursor = try f.store.currentChangeCursor()
    #expect(try f.store.commitDocumentState(checkpoint) == accepted)
    #expect(try f.store.currentChangeCursor() == cursor)
    state = try f.store.loadDocumentState(f.id)
    _ = try f.store.commitDocumentState(command(&state, source: source, value: .number(7), actor: f.actor))
    _ = try f.store.commitDocumentState(command(&state, source: source, value: .number(4), actor: f.actor))
    let before = try f.store.loadDocumentState(f.id), finalCursor = try f.store.currentChangeCursor()
    #expect(try f.store.commitDocumentState(checkpoint) == .stateChanged(documentID: f.id,
      currentStateVersion: before.records.first { $0.id == source.id }?.valueVersion))
    #expect(try f.store.loadDocumentState(f.id) == before)
    #expect(try f.store.currentChangeCursor() == finalCursor)
  }

  @Test func largeDetachedEventsKeepFIFOReceiptsAndUseOnlyAdmittedReads() throws {
    let f = try fixture(), source = try source(f)
    let payload = String(repeating: "x", count: 5 * 1_024 * 1_024)
    var cursor = try f.store.currentChangeCursor(), previous: ContentFieldVersion?
    var last: NotebookDocumentStatePublication?
    for sequence in 1...3 {
      let value: JSONValue = .object(["sequence": .number(Double(sequence)), "payload": .string(payload)])
      let accepted = try #require(try f.store.commitDocumentState(documentID: f.id, programID: source.id,
        programPath: path, value: value, sourceBasis: source.sourceBasis, actor: f.actor))
      if let previous {
        #expect(accepted.record.valueVersion.includes(previous) && !previous.includes(accepted.record.valueVersion))
      }
      previous = accepted.record.valueVersion; last = accepted
      #expect(try f.store.currentChangeCursor() == cursor + 1); cursor += 1
      let reopened = NotebookStore(root: f.root)
      #expect(throws: NotebookStorageError.self) {
        try reopened.readDocumentProgram(documentID: f.id, instanceID: source.id, programPath: path)
      }
      let bytes = try reopened.documentProgramStateReadBytes(documentID: f.id, instanceID: source.id)
      #expect(bytes > payload.utf8.count)
      #expect(throws: NotebookStorageError.limitExceeded("program_state_admission")) {
        try reopened.readDocumentProgramState(documentID: f.id, instanceID: source.id, programPath: path, admittedBytes: bytes-1)
      }
      let read = try reopened.readDocumentProgramState(documentID: f.id, instanceID: source.id, programPath: path, admittedBytes: bytes)
      #expect(read.state == value && read.stateVersion == accepted.record.valueVersion)
      #expect(read.sourceBasis == source.sourceBasis)
    }
    let final = try #require(last)
    #expect(try f.store.checkpointDocumentState(documentID: f.id, programID: source.id,
      programPath: path, value: final.record.value, sourceBasis: source.sourceBasis,
      stateVersion: previous, actor: f.actor) == final)
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(throws: NotebookStorageError.self) {
      try f.store.readDocumentProgram(documentID: f.id, instanceID: source.id, programPath: path)
    }
  }

  @Test func admittedWindowsReassembleMoreThan4096StateFragments() throws {
    let f = try fixture(), source = try source(f)
    let value = JSONValue.object(["records": .array((0..<4_200).map {
      .object(["id": .string("part-\($0)"), "value": .number(Double($0))])
    })])
    let accepted = try #require(try f.store.commitDocumentState(documentID: f.id, programID: source.id,
      programPath: path, value: value, sourceBasis: source.sourceBasis, actor: f.actor))
    let address = stateFile(f.id) + "#/records/@" + fieldKey([collaborationIdentity(source.id)])
    #expect(try f.store.storedFragments(address: address).count > 4096)
    #expect(throws: NotebookStorageError.self) {
      try f.store.readDocumentProgram(documentID: f.id, instanceID: source.id, programPath: path)
    }
    let bytes = try f.store.documentProgramStateReadBytes(documentID: f.id, instanceID: source.id)
    let read = try f.store.readDocumentProgramState(documentID: f.id, instanceID: source.id, programPath: path, admittedBytes: bytes)
    #expect(read.state == value && read.stateVersion == accepted.record.valueVersion)
  }

  @Test(arguments: ["program-html", "program-css", "program-js", "program-config"])
  func everyExecutableFileRejectsLateEventsWithoutErasingAcceptedState(fileID: String) throws {
    let f = try fixture(), source = try source(f)
    var state = try f.store.loadDocumentState(f.id)
    let accepted = try command(&state, source: source, value: .number(17), actor: f.actor)
    #expect(try f.store.commitDocumentState(accepted) == accepted.expectedResult)
    let pending = try command(&state, source: source, value: .number(99), actor: f.actor)
    let file = try f.file(fileID)
    let changed = fileID == "program-config" ? #"{"initialState":9}"# : file.file.source + "\n/* changed */"
    _ = try f.apply([f.patch(file, to: changed)])
    let current = try self.source(f)
    #expect(current.sourceBasis != source.sourceBasis)
    let before = try f.store.loadDocumentState(f.id), cursor = try f.store.currentChangeCursor()
    #expect(try f.store.commitDocumentState(pending) == .targetChanged(documentID: f.id, currentSourceBasis: current.sourceBasis))
    #expect(try f.store.commitDocumentState(accepted) == .targetChanged(documentID: f.id, currentSourceBasis: current.sourceBasis))
    #expect(try f.store.checkpointDocumentState(documentID: f.id, programID: source.id,
      programPath: path, value: .number(99), sourceBasis: source.sourceBasis,
      stateVersion: accepted.record.valueVersion, actor: f.actor) == nil)
    #expect(try f.store.loadDocumentState(f.id) == before && before.value(for: source.id) == .number(17))
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test(arguments: ["program-html", "program-css", "program-js", "program-config", "delete-recreate"])
  func executableABAAndFileRecreationFenceThePreviousHeap(fileID: String) throws {
    let f = try fixture(), source = try source(f)
    let key = fileID == "delete-recreate" ? "program-js" : fileID
    var document = try f.store.loadDocument(f.id)
    let original = try #require(document.files.first { $0.id == key })
    let changed: Bool
    if fileID == "delete-recreate" {
      changed = document.replaceContent(files: document.files.filter { $0.id != key }, actor: f.actor)
    } else {
      changed = document.replaceFileSource(id: key,
        source: key == "program-config" ? #"{"initialState":9}"# : original.source + "\n/* alternate */", actor: f.actor)
    }
    #expect(changed); _ = try f.store.saveMergedDocument(document)
    document = try f.store.loadDocument(f.id)
    let restored = document.replaceContent(files: document.files.filter { $0.id != key } + [original], actor: f.actor)
    #expect(restored); _ = try f.store.saveMergedDocument(document)
    let current = try self.source(f)
    #expect(current.programPackage == source.programPackage && current.sourceBasis != source.sourceBasis)
    let cursor = try f.store.currentChangeCursor()
    #expect(try f.store.commitDocumentState(documentID: f.id, programID: source.id,
      programPath: path, value: .number(42), sourceBasis: source.sourceBasis, actor: f.actor) == nil)
    #expect(try f.store.checkpointDocumentState(documentID: f.id, programID: source.id,
      programPath: path, value: .number(42), sourceBasis: source.sourceBasis, stateVersion: nil, actor: f.actor) == nil)
    #expect(try f.store.loadDocumentState(f.id).records.isEmpty)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test func losingConcurrentFileEditChangesCASButNotTheWinningExecutor() throws {
    let f = try fixture(), base = try f.store.loadDocument(f.id)
    var winning = base, losing = base
    let humanEdit = winning.replaceFileSource(id: "program-js", source: "window.winner = true;", actor: UUID())
    let agentEdit = losing.replaceFileSource(id: "program-js", source: "window.loser = true;", actor: UUID())
    #expect(humanEdit && agentEdit)
    var metadata = base.collaboration ?? CollaborativeContent()
    metadata.record(before: try .encode(base), after: try .encode(losing),
      beforeStamp: base.contentStamp, stamp: losing.contentStamp, human: false)
    losing = try JSONValue.encode(losing).setting("collaboration", .encode(metadata)).decode(DocumentDocument.self)
    _ = try f.store.saveMergedDocument(winning)
    let before = try source(f), cas = try f.file("program-js").sourceVersion
    _ = try f.store.saveMergedDocument(losing)
    let after = try source(f)
    #expect(after.sourceBasis == before.sourceBasis && after.programPackage == before.programPackage)
    #expect(try f.file("program-js").sourceVersion != cas)
    #expect(try f.file("program-js").file.source == "window.winner = true;")
    let accepted = try #require(try f.store.commitDocumentState(documentID: f.id, programID: before.id,
      programPath: path, value: .number(7), sourceBasis: before.sourceBasis, actor: f.actor))
    #expect(accepted.record.value == .number(7))
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func stateValueClockAndDeliveryRemainOneFailureBoundary(fault: NotebookStorageFault) throws {
    let f = try fixture(), source = try source(f)
    var state = try f.store.loadDocumentState(f.id)
    let before = state, cursor = try f.store.currentChangeCursor()
    let command = try command(&state, source: source, value: .number(5), actor: f.actor)
    let failing = NotebookStore(root: f.root) { point in
      if String(describing: point) == String(describing: fault) { throw Fault.injected }
    }
    #expect(throws: Fault.self) { try failing.commitDocumentState(command) }
    if case .afterCommit = fault {
      #expect(try f.store.loadDocumentState(f.id) == state)
      #expect(try f.store.currentChangeCursor() == cursor + 1)
    } else {
      #expect(try f.store.loadDocumentState(f.id) == before)
      #expect(try f.store.currentChangeCursor() == cursor)
    }
    #expect(try f.store.commitDocumentState(command) == command.expectedResult)
    #expect(try f.store.currentChangeCursor() == cursor + 1)
  }

  @Test func addressedStateWritesDoNotDecodeOrRenumberRetiredValues() throws {
    let f = try fixture(), source = try source(f), file = stateFile(f.id)
    let root = file + "#", clock = VersionStamp(counter: 100_000, actor: f.actor)
    try f.store.commandTransaction {
      for index in 0..<100_000 {
        let record = DocumentStateRecord(id: "retired-\(index)", value: .number(Double(index)), stamp: clock)
        try f.store.writeFragment(.init(address: root + "/records/@" + record.id, file: file,
          parent: root, collection: "records", member: record.id, position: index,
          value: try .encode(record), collections: []), database: f.store.currentSQL!)
      }
      let header = try #require(f.store.storedFragments(address: root, descendants: false).first)
      try f.store.writeFragment(header.replacing(value: header.value.setting("stamp", try .encode(clock))), database: f.store.currentSQL!)
      let hash = try f.store.currentSQL!.putBlob(Data("unrequested retired state".utf8))
      try f.store.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(root + "/records/@retired-50000")])
      // The sibling keeps its valid address/path metadata but has no decodable
      // text body. Only a hidden full-document source read can encounter it.
      let address = documentFile(f.id) + "#/files/@section"
      let sibling = try #require(f.store.storedFragments(address: address, descendants: false).first)
      try f.store.writeFragment(sibling.replacing(value: sibling.value.setting("source", .number(7))), database: f.store.currentSQL!)
    }
    #expect(throws: DecodingError.self) { try f.store.readDocumentFile(documentID: f.id, fileID: "section") }
    let retained = try f.store.storedFragments(address: root + "/records/@retired-75000")
    let cursor = try f.store.currentChangeCursor()
    let count = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    count.initialize(to: 0); defer { count.deinitialize(count: 1); count.deallocate() }
    try f.store.commandTransaction {
      sqlite3_progress_handler(f.store.currentSQL!.handle, 1, { raw in
        let count = raw!.assumingMemoryBound(to: Int.self)
        count.pointee += 1; return count.pointee > 200_000 ? 1 : 0
      }, count)
      defer { sqlite3_progress_handler(f.store.currentSQL!.handle, 0, nil, nil) }
      let first = try #require(try f.store.commitDocumentState(documentID: f.id, programID: source.id,
        programPath: path, value: .number(1), sourceBasis: source.sourceBasis, actor: f.actor))
      #expect(first.record.stamp.counter == clock.counter + 1)
      #expect(try f.store.commitDocumentState(documentID: f.id, programID: source.id,
        programPath: path, value: .number(1), sourceBasis: source.sourceBasis, actor: f.actor) == first)
    }
    #expect(count.pointee > 0 && count.pointee < 200_000)
    #expect(try f.store.currentChangeCursor() == cursor + 1)
    #expect(try f.store.storedFragments(address: root + "/records/@retired-75000") == retained)
    let changed = try f.store.readChangedAddresses(after: cursor, through: f.store.currentChangeCursor()).addresses
    #expect(Set(changed) == [root, root + "/records/@" + fieldKey([source.id])])
  }
}
