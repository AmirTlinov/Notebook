import Foundation
import NotebookCore
import NotebookTypesetter
import WebKit

/// One mounted document shares immutable bridge inputs. The page coordinators
/// still own their existing WebKit instances; this session never creates one.
@MainActor
final class DocumentRenderSession {
  let documentID: UUID
  private final class WeakSource {
    weak var value: DocumentSourceSnapshot?
    init(_ value: DocumentSourceSnapshot) { self.value = value }
  }
  private final class WeakState {
    weak var value: DocumentStateSnapshot?
    init(_ value: DocumentStateSnapshot) { self.value = value }
  }
  private var sources: [VersionStamp: [WeakSource]] = [:]
  private var states: [WeakState] = []

  init(documentID: UUID) { self.documentID = documentID }

  func source(_ document: DocumentDocument, store: NotebookStore? = nil) -> DocumentSourceSnapshot {
    precondition(document.id == documentID)
    if let snapshot = sources[document.contentStamp]?.lazy.compactMap(\.value).first(where: { $0.matches(document) && $0.canRead(using: store) }) { return snapshot }
    sources = sources.compactMapValues { values in
      let live = values.filter { $0.value != nil }; return live.isEmpty ? nil : live
    }
    let reuse = sources.values.lazy.flatMap { $0 }.compactMap { $0.value?.printReuse }.first
    let snapshot = DocumentSourceSnapshot(document, store: store, reuse: reuse)
    sources[document.contentStamp, default: []].append(WeakSource(snapshot))
    return snapshot
  }

  func state(_ journal: DocumentStateJournal, blockIDs: Set<String>? = nil) -> DocumentStateSnapshot {
    precondition(journal.id == documentID)
    return state(records: journal.records.filter { blockIDs?.contains($0.id) ?? true })
  }

  func state(records: [DocumentStateRecord]) -> DocumentStateSnapshot {
    states = states.filter { $0.value != nil }
    if let snapshot = states.lazy.compactMap(\.value).first(where: { $0.records == records }) { return snapshot }
    let snapshot = DocumentStateSnapshot(documentID: documentID, records: records)
    states.append(WeakState(snapshot))
    return snapshot
  }

  func source(key: String) -> DocumentSourceSnapshot? {
    sources.values.lazy.flatMap { $0 }.compactMap(\.value).first { $0.message.key == key }
  }
}

struct DocumentSourceMessage: Encodable, Sendable {
  let key: String
  let documentID: UUID
  let paper: DocumentPaperLayout
  let files: [DocumentFile]
  let programs: [DocumentProgramSource]
  let programHeights: [String: Double]
  private enum CodingKeys: String, CodingKey { case key, documentID, paper, files, programs, programHeights }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(key, forKey: .key); try c.encode(documentID, forKey: .documentID)
    try c.encode(paper, forKey: .paper)
    // The browser needs addresses, never another editable copy of source bytes.
    try c.encode(files.map { ["id": $0.id, "path": $0.path] }, forKey: .files)
    try c.encode(programHeights, forKey: .programHeights)
    try c.encode(programs.map { program in JSONValue.object([
      "id": .string(program.id), "path": .string(program.path), "programPackage": .string(program.programPackage),
      "initialState": program.initialState, "sourceBasis": .string(program.sourceBasis)]) }, forKey: .programs)
  }
}

struct DocumentStateMessage: Encodable, Sendable {
  let key: String
  let documentID: UUID
  let states: [String: JSONValue]
  let versions: [String: ContentFieldVersion]
}

/// Pages share one immutable source. Its body crosses the browser boundary
/// only as addressed page metadata; the native editor reads the actual files.
@MainActor
final class DocumentSourceSnapshot {
  private let key = UUID().uuidString
  let document: DocumentDocument
  private let store: NotebookStore?
  var message: DocumentSourceMessage { .init(key: key, documentID: document.id, paper: paper(on: 0), files: document.files, programs: programs, programHeights: layout?.programHeights(ids: programIDs) ?? [:]) }
  let stamp: VersionStamp
  var programs: [DocumentProgramSource] { preparation?.programs ?? [] }
  var programIDs: Set<String> { preparation?.programIDs ?? [] }
  var programFailures: [String: String] { preparation?.programFailures ?? [:] }
  private var blockIDs: Set<String> { Set(document.files.map(\.id)).union(programIDs) }
  private(set) var layout: DocumentLayoutRecord?
  private var preparation: DocumentPagePreparation?
  private var reuse: DocumentPrintReuse?
  var printReuse: DocumentPrintReuse? { preparation?.printReuse }
  private var layoutObservers: [UUID: (DocumentLayoutRecord) -> Void] = [:]
  var onProgramsChanged: () -> Void = {}
  private(set) var preparationCount = 0
  private var receiptLayoutMismatch: String?

  init(_ document: DocumentDocument, store: NotebookStore? = nil, reuse: DocumentPrintReuse? = nil) {
    self.document = document; self.store = store; stamp = document.contentStamp; self.reuse = reuse
  }
  func paper(on page: Int) -> DocumentPaperLayout { layout?.paper(on: page) ?? .uncompiled }
  func program(_ id: String) -> DocumentProgramSource? { programs.first { $0.id == id } }

  func matches(_ document: DocumentDocument) -> Bool { self.document == document }
  func canRead(using store: NotebookStore?) -> Bool { store == nil || self.store?.root == store?.root }

  func programIDs(on page: Int) -> Set<String>? {
    guard let layout, (0..<layout.pageCount).contains(page) else { return nil }
    return layout.blockIDs(on: [page], kind: .program).intersection(programIDs)
  }

  func preparedPage(_ index: Int, hostID: UUID,
    resources: SceneRenderResources, priority: NotebookTypesetter.Priority = .current, onAdmissionWait: @escaping (Bool) -> Void = { _ in },
    onLayoutChanged: @escaping (DocumentLayoutRecord) -> Void = { _ in }) async throws -> DocumentPreparedPage {
    layoutObservers[hostID] = onLayoutChanged
    ensurePreparation(resources: resources)
    let prepared: DocumentPreparedPage
    do { prepared = try await preparation!.page(index, hostID: hostID, priority: priority, onAdmissionWait: onAdmissionWait) }
    catch {
      if preparation?.layout != nil { try acceptPreparedLayout() }
      throw error
    }
    try acceptPreparedLayout()
    return prepared
  }

  func preparePrograms(on pages: Set<Int>, retaining ids: Set<String> = []) async throws {
    guard let preparation, let layout else { return }
    try await preparation.preparePrograms(layout.blockIDs(on: pages, kind: .program).union(ids))
  }

  private func ensurePreparation(resources: SceneRenderResources) {
    if preparation == nil {
      preparationCount += 1
      preparation = DocumentPagePreparation(document: document, sourceKey: key, store: store, resources: resources, reuse: reuse)
      reuse = nil
      preparation?.onProgramsChanged = { [weak self] in self?.onProgramsChanged() }
      preparation?.onLayoutAccepted = { [weak self] record in
        guard let self else { return }
        if let layout, layout !== record { guard layout.matches(record) else { throw DocumentSessionError.inconsistentLayout } }
        else { layout = record }
        for observer in Array(layoutObservers.values) { observer(layout!) }
      }
    }
  }
  /// Accepted opening demand starts immutable print work before any native
  /// host/window exists. The same source is later borrowed by its paper owner.
  func prepareOpening(pageIndex: Int, hostID: UUID, resources: SceneRenderResources) async throws {
    try Task.checkCancellation()
    ensurePreparation(resources: resources)
    preparation!.retainPage(pageIndex, hostID: hostID)
    _ = try await preparation!.printedSource(priority: .current)
    try acceptPreparedLayout()
  }
  func printedSource(resources: SceneRenderResources, priority: NotebookTypesetter.Priority = .current) async throws -> DocumentPrintedSource {
    ensurePreparation(resources: resources)
    return try await preparation!.printedSource(priority: priority)
  }
  func promotePreparation(to priority: NotebookTypesetter.Priority) { preparation?.promote(to: priority) }
  func sourceOffset(fileID: String, pageIndex: Int, x: Double, y: Double) -> Int? {
    preparation?.sourceOffset(fileID: fileID, pageIndex: pageIndex, x: x, y: y)
  }

  private func acceptPreparedLayout() throws {
    guard let measured = preparation?.layout else { throw DocumentSessionError.invalidLayout }
    if let layout, layout !== measured, !layout.matches(measured) {
      receiptLayoutMismatch = "handoff pages=\(layout.pageCount)/\(measured.pageCount); old=\(Array(layout.regions.prefix(3))); new=\(Array(measured.regions.prefix(3)))"
      throw DocumentSessionError.inconsistentLayout
    }
    layout = layout ?? measured
  }

  func retainPage(_ index: Int, hostID: UUID) { preparation?.retainPage(index, hostID: hostID) }
  func releasePage(hostID: UUID, in web: WKWebView?) {
    // An idle executor releases page demand, not its mounted source metadata.
    // A physical WebKit/source retirement ends the observer as well.
    if web != nil { layoutObservers[hostID] = nil }
    preparation?.releasePage(hostID: hostID, in: web)
  }
  func discardIdlePreparation() async { await preparation?.discardIdlePreparation() }
  var pendingPreparationReaderCount: Int { preparation?.pendingReaderCount ?? 0 }
  var retainedPageIndices: Set<Int> { preparation?.retainedPageIndices ?? [] }
  var compiledPageCount: Int { preparation?.compiledPageCount ?? 0 }
  var measurementCount: Int { preparation?.measurementCount ?? 0 }
  var preparedSourceBlockCount: Int { preparation?.preparedSourceBlockCount ?? 0 }
  var preparationPhasesMS: [String: Double] { preparation?.preparationPhasesMS ?? [:] }
  var lastPreparationLayoutMismatch: String? { receiptLayoutMismatch ?? preparation?.lastLayoutMismatch }

  func retryPagePreparation(_ pageIndex: Int) {
    if preparation?.failed == true { preparation = nil }
    else { preparation?.retryPage(pageIndex) }
  }

  func acceptLayout(_ receipt: NSDictionary, geometry: WorkspaceItemGeometry) throws -> DocumentLayoutRecord {
    guard let scope = receipt["layoutScope"] as? String, scope == "source" || scope == "page",
      scope != "page" || layout != nil else { throw DocumentSessionError.invalidLayout }
    let measured = try DocumentLayoutRecord(receipt: receipt, sourceKey: message.key, blockIDs: blockIDs, geometry: geometry)
    if let layout {
      if receipt["layoutScope"] as? String == "page" {
        guard let index = receipt["pageIndex"] as? Int, (0..<layout.pageCount).contains(index),
          layout.matches(measured, pageIndex: index) else {
          let page = receipt["pageIndex"] as? Int
          receiptLayoutMismatch = "installed page=\(String(describing: page)); pages=\(layout.pageCount)/\(measured.pageCount); old=\(Array(layout.regions.filter { $0.pageIndex == page }.prefix(3))); new=\(Array(measured.regions.prefix(3)))"
          throw DocumentSessionError.inconsistentLayout
        }
      } else if !layout.matches(measured) {
        receiptLayoutMismatch = "source receipt pages=\(layout.pageCount)/\(measured.pageCount); old=\(Array(layout.regions.prefix(3))); new=\(Array(measured.regions.prefix(3)))"
        throw DocumentSessionError.inconsistentLayout
      }
      return layout
    }
    layout = measured
    return measured
  }

}

@MainActor
final class DocumentStateSnapshot {
  let message: DocumentStateMessage
  let records: [DocumentStateRecord]
  private var encoding: Task<NotebookProgramStateEncoding, Error>?
  private(set) var encodingCount = 0

  init(documentID: UUID, records: [DocumentStateRecord]) {
    self.records = records
    message = .init(key: UUID().uuidString, documentID: documentID,
      states: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.value) }),
      versions: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.valueVersion) }))
  }

  func encodedState(resources: SceneRenderResources) async throws -> NotebookProgramStateEncoding {
    if encoding == nil {
      encodingCount += 1
      let message = message
      encoding = Task { @MainActor in
        let value: JSONValue = .object(["key": .string(message.key), "documentID": .string(message.documentID.uuidString),
          "states": .object(message.states), "versions": try .encode(message.versions)])
        return try await NotebookProgramStateEncoding.prepare(value, resources: resources)
      }
    }
    return try await encoding!.value
  }

  isolated deinit { encoding?.cancel() }
}

func canonicalDocumentJSON<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}

enum DocumentSessionError: Error, LocalizedError {
  case invalidLayout
  case inconsistentLayout
  var errorDescription: String? {
    switch self {
    case .invalidLayout: "document_layout_invalid"
    case .inconsistentLayout: "document_layout_inconsistent"
    }
  }
}
