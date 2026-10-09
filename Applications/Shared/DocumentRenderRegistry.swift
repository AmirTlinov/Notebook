import Foundation
import NotebookCore
import Observation
import WebKit

/// Failed execution still reports the addressed diagnostics from its exact
/// source frame; a generic WebKit error must not erase the program identity.
struct DocumentRenderingFailure: Error, LocalizedError {
  let diagnostics: [RenderDiagnostic]
  let buildID: String?
  var programs: [DocumentProgramCheck] = []
  var errorDescription: String? { diagnostics.first?.message }


}

enum DocumentRegionKind: String, Codable, Sendable { case file, program }

struct DocumentBlockRegion: Equatable, Sendable {
  var kind: DocumentRegionKind = .file
  let id: String
  let pageIndex: Int
  let frame: PageRect
  let sourceOffset: Double
}

enum DocumentPresentationScope {
  case paper, block(String), region(PageRect), page
}

/// Native canonical layout and installed paper name exact physical fragments.
@MainActor
@Observable
final class DocumentRenderRegistry {
  static let shared = DocumentRenderRegistry()
  @MainActor struct Entry {
    let token: String
    let pageIndex: Int
    let layout: DocumentLayoutRecord
    var regions: [DocumentBlockRegion] { layout.regions }
    let diagnostics: [RenderDiagnostic]
    let programs: [DocumentProgramCheck]
  }
  @MainActor private struct PublishedEntry {
    let token: String
    let sourceStamp: VersionStamp
    let programIDs: Set<String>
    let pageIndex: Int
    weak var layout: DocumentLayoutRecord?
    let diagnostics: [RenderDiagnostic]
    let programs: [DocumentProgramCheck]
    var retained: Entry? {
      layout.map { Entry(token: token, pageIndex: pageIndex, layout: $0, diagnostics: diagnostics, programs: programs) }
    }
  }
  // The registry locates a measured source; it is not another cache owner.
  // A live source, raster entry or an actual reader retains the shared layout.
  private var entries: [UUID: [PublishedEntry]] = [:]
  private struct SessionKey: Hashable {
    let documentID: UUID
    let resources: ObjectIdentifier
  }
  private final class WeakSession {
    weak var value: DocumentRenderSession?
    init(_ value: DocumentRenderSession) { self.value = value }
  }
  @ObservationIgnored private var sessions: [SessionKey: WeakSession] = [:]

  func session(documentID: UUID, resources: SceneRenderResources) -> DocumentRenderSession {
    let key = SessionKey(documentID: documentID, resources: ObjectIdentifier(resources))
    if let value = sessions[key]?.value { return value }
    sessions = sessions.filter { $0.value.value != nil }
    let value = DocumentRenderSession(documentID: documentID)
    sessions[key] = WeakSession(value)
    return value
  }
  private struct LiveSurface {
    let documentID: UUID
    let token: String
    let paperToken: String
    let pageIndex: Int
    let generation: UInt64
    let isAttached: @MainActor (DocumentPresentationScope) -> Bool
    let paper: @MainActor () -> DocumentPaperRaster?
  }
  @ObservationIgnored private var liveSurfaces: [UUID: LiveSurface] = [:]
  private struct LiveObserver {
    let documentID: UUID
    let changed: @MainActor () -> Void
  }
  @ObservationIgnored private var liveObservers: [UUID: LiveObserver] = [:]

  func observeLive(documentID: UUID, changed: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID(); liveObservers[id] = .init(documentID: documentID, changed: changed); return id
  }

  func removeLiveObserver(_ id: UUID) { liveObservers[id] = nil }
  func checkpointFocusedProgram(documentID: UUID, resume: Bool) async -> Bool {
    #if os(iOS)
    await DocumentPagePresentationOwner.checkpointFocusedProgram(documentID: documentID, resume: resume)
    #else
    true
    #endif
  }

  func checkpointPrograms(documentID: UUID? = nil, resume: Bool) async -> Bool {
    #if os(iOS)
    await DocumentPagePresentationOwner.checkpointPrograms(documentID: documentID, resume: resume)
    #else
    true
    #endif
  }

  func resumePrograms(continuing: @MainActor () -> Bool = { true }) async {
    #if os(iOS)
      await DocumentPagePresentationOwner.resumePrograms(continuing: continuing)
    #endif
  }

  func retryRetiringPrograms() {
    #if os(iOS)
    DocumentPagePresentationOwner.retryRetiringPrograms()
    #endif
  }

  /// Layout history can resolve an address, but only the exact mounted current
  /// surface can confirm what the person is seeing now.
  func hasLiveSurface(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int,
    scope: DocumentPresentationScope = .page) -> Bool {
    if case .paper = scope {
      let token = DocumentSnapshotCache.paperToken(sourceRevision: document.contentStamp.revision, pageIndex: pageIndex)
      return liveSurfaces.values.contains {
        $0.documentID == document.id && $0.paperToken == token && $0.pageIndex == pageIndex && $0.isAttached(.paper)
      }
    }
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndex)
    return liveSurfaces.values.contains {
      $0.documentID == document.id && $0.token == token && $0.pageIndex == pageIndex && $0.isAttached(scope)
    }
  }

  func liveSurfaceIdentity(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int)
    -> (hostID: UUID, generation: UInt64)? {
    let token = DocumentSnapshotCache.paperToken(sourceRevision: document.contentStamp.revision, pageIndex: pageIndex)
    guard let entry = liveSurfaces.first(where: {
      $0.value.documentID == document.id && $0.value.paperToken == token && $0.value.pageIndex == pageIndex
        && $0.value.isAttached(.paper)
    }) else { return nil }
    return (entry.key,entry.value.generation)
  }

  /// Borrow the installed, accounted paper pixels. A prepared or detached page
  /// is not a mask for feedback on the current source.
  func installedPaper(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int) -> DocumentPaperRaster? {
    let token = DocumentSnapshotCache.paperToken(sourceRevision: document.contentStamp.revision, pageIndex: pageIndex)
    return liveSurfaces.values.first {
      $0.documentID == document.id && $0.paperToken == token && $0.pageIndex == pageIndex && $0.isAttached(.paper)
    }?.paper()
  }

  func publishLive(documentID: UUID, token: String, pageIndex: Int, hostID: UUID, generation: UInt64,
    paperToken: String? = nil,
    paper: @escaping @MainActor () -> DocumentPaperRaster? = { nil },
    isAttached: @escaping @MainActor (DocumentPresentationScope) -> Bool) {
    if let previous = liveSurfaces[hostID] {
      if previous.generation > generation { return }
    }
    liveSurfaces[hostID] = .init(documentID: documentID, token: token, paperToken: paperToken ?? token, pageIndex: pageIndex,
      generation: generation, isAttached: isAttached, paper: paper)
    for observer in Array(liveObservers.values) where observer.documentID == documentID { observer.changed() }
  }

  func revokeLive(hostID: UUID, through generation: UInt64) {
    guard let previous = liveSurfaces[hostID], previous.generation <= generation else { return }
    liveSurfaces[hostID] = nil
  }

  func entry(document: DocumentDocument, pageIndex: Int) -> Entry? {
    return entries[document.id]?.last { $0.layout != nil && $0.sourceStamp == document.contentStamp && $0.pageIndex == pageIndex }?.retained
  }

  func layout(document: DocumentDocument) -> DocumentLayoutRecord? {
    entries[document.id]?.last(where: { $0.layout != nil && $0.sourceStamp == document.contentStamp })?.layout
  }

  func geometry(document: DocumentDocument, pageIndex: Int = 0) -> WorkspaceItemGeometry {
    layout(document: document)?.paper(on: pageIndex).geometry ?? .uncompiledDocument
  }

  func program(documentID: UUID, id: String) -> DocumentProgramSource? {
    #if os(iOS)
      return DocumentPagePresentationOwner.program(documentID: documentID, id: id)
    #else
    nil
    #endif
  }

  func programs(documentID: UUID) -> [DocumentProgramSource] {
    #if os(iOS)
      return DocumentPagePresentationOwner.programs(documentID: documentID)
    #else
    []
    #endif
  }

  func programIDs(document: DocumentDocument, pageIndex: Int) -> Set<String>? {
    guard let entry = entries[document.id]?.last(where: { $0.layout != nil && $0.sourceStamp == document.contentStamp }),
      let layout = entry.layout, (0..<layout.pageCount).contains(pageIndex) else { return nil }
    return layout.blockIDs(on: [pageIndex], kind: .program).intersection(entry.programIDs)
  }

  func regions(document: DocumentDocument) -> [DocumentBlockRegion] {
    layout(document: document)?.regions ?? []
  }

  func layoutReferenceCount(documentID: UUID) -> Int { entries[documentID]?.count ?? 0 }

  func publishNative(source: DocumentSourceSnapshot, token: String, pageIndex: Int,
    diagnostics: [RenderDiagnostic] = [], programs: [DocumentProgramCheck] = []) throws {
    guard let layout = source.layout else { throw DocumentSessionError.invalidLayout }
    let documentID = source.document.id
    guard (0..<layout.pageCount).contains(pageIndex) else { throw DocumentSessionError.invalidLayout }
    layout.whenReleased(by: self) { [weak self] in
      guard let self else { return }
      let live = entries[documentID]?.filter { $0.layout != nil } ?? []
      entries[documentID] = live.isEmpty ? nil : live
    }
    var values = entries[documentID]?.filter { $0.layout != nil } ?? []
    if let previous = values.last(where: { $0.token == token && $0.pageIndex == pageIndex }),
      previous.layout === layout, previous.diagnostics == diagnostics, previous.programs == programs { return }
    values.removeAll { $0.token == token && $0.pageIndex == pageIndex }
    values.append(.init(token: token, sourceStamp: source.stamp, programIDs: source.programIDs,
      pageIndex: pageIndex, layout: layout, diagnostics: diagnostics, programs: programs))
    entries[documentID] = Array(values.suffix(8))
  }
}
