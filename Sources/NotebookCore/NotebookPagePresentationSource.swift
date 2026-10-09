import CoreGraphics
import Foundation

/// Native painting and contact borrow page material, ink and causal sources.
/// Durable whole-page persistence remains an explicit PageDocument operation.
public protocol NotebookPagePresentationSource: Sendable {
  var id: UUID { get }
  var size: PageSize { get }
  var drawingStamp: VersionStamp { get }
  var agentStamp: VersionStamp { get }
  var elements: [AgentElement] { get }
  var elementSourceIdentity: ObjectIdentifier { get }
  var elementSourceSnapshot: NotebookElementSourceSnapshot { get }
  var inkSource: PageInkSource { get }
  var preparedInkDrawing: PageInkDrawing? { get }
  var preparedElementErasures: InkElementErasureMap? { get }
  var graphicPresentation: NotebookGraphicPresentation { get }
  var materialCoverage: CGRect? { get }
  func graphicGraph() -> NotebookGraphicGraph
  func element(id: String) -> AgentElement?
  func interactionElements(ids: Set<String>, includingIdentityAliases: Bool) -> [AgentElement]
  func displayElements(graphicIDs: Set<String>) -> [AgentElement]
  func elementIdentityStamp(_ id: String) -> VersionStamp?
  func nativeElementSource(id: String) -> NotebookNativeElementSource?
  func programStateBasis(_ id: String) -> NotebookProgramStateBasis?
  func referenceRevision(elementID: String?) throws -> String
  func frozenForPresentation() -> any NotebookPagePresentationSource
  func prepareLiveInkChange(_ mutation: PageInkMutation, stamp: VersionStamp) throws -> PreparedPageInkChange
  @discardableResult func publishLiveInkChange(_ change: PreparedPageInkChange) -> Bool
}

extension NotebookPagePresentationSource {
  public func interactionElements(ids: Set<String>) -> [AgentElement] { interactionElements(ids: ids, includingIdentityAliases: false) }
  public func prepareInkForPresentation() throws { try inkSource.prepareForPresentation() }
  public func inkDrawing() throws -> PageInkDrawing { try inkSource.drawing() }
  public func coversMaterial(in bounds: CGRect) -> Bool { materialCoverage?.contains(bounds) ?? true }
}

extension PageDocument: NotebookPagePresentationSource {
  public var materialCoverage: CGRect? { nil }
  public func nativeElementSource(id: String) -> NotebookNativeElementSource? {
    let body = element(id: id), versions = collaboration?.elementVersions(id: id) ?? [:]
    guard body != nil || !versions.isEmpty else { return nil }
    return .init(target: .init(kind: .page, id: self.id), id: body?.id ?? id, page: body, versions: versions)
  }
}

/// A finite, input-ready native source. Its material is immutable and its ink
/// owner publishes persistent roots just as a complete page does. Neither this
/// value nor its drawing can be submitted as a whole-page replacement.
public struct NotebookPageMaterialSource: NotebookPagePresentationSource {
  private final class Material: Sendable {
    let snapshot: NotebookElementSourceSnapshot
    init(_ window: NotebookPageMaterialWindow) { snapshot = .init(pageMaterial: window) }
  }
  private let material: Material
  private let ink: PageInkDrawingCache
  public let inkWindow: NotebookPageInkWindow
  public let window: NotebookPageMaterialWindow
  public var id: UUID { window.page.position.pageID }
  public var size: PageSize { window.page.size }
  public var drawingStamp: VersionStamp { ink.stamp(fallback: inkWindow.source.stamp) }
  public var agentStamp: VersionStamp { window.page.agentStamp }
  public var elements: [AgentElement] { window.elements }
  public var elementSourceIdentity: ObjectIdentifier { ObjectIdentifier(material) }
  public var elementSourceSnapshot: NotebookElementSourceSnapshot { material.snapshot }
  public var inkSource: PageInkSource { .init(source: ink.source(data: Data(), stamp: inkWindow.source.stamp)) }
  public var preparedInkDrawing: PageInkDrawing? { inkSource.preparedDrawing }
  public var preparedElementErasures: InkElementErasureMap? { inkSource.preparedElementErasures }
  public var graphicPresentation: NotebookGraphicPresentation { window.graphicPresentation }
  public var materialCoverage: CGRect? { window.coverage.intersection(inkWindow.coverage) }

  public init(material: NotebookPageMaterialWindow, ink: NotebookPageInkWindow) throws {
    guard material.page.position.pageID == ink.pageID, material.header.workspaceID == ink.workspaceID,
      material.snapshotIdentity == ink.snapshotIdentity, material.readCursor == ink.readCursor,
      material.sourceRevision == ink.sourceRevision, material.page.drawingStamp == ink.source.stamp,
      ink.coverage.contains(material.coverage) else { throw NotebookStorageError.transactionConflict }
    window = material; self.material = .init(material); inkWindow = ink; self.ink = .init(source: ink.source.source)
  }
  private init(window: NotebookPageMaterialWindow, material: Material, inkWindow: NotebookPageInkWindow, ink: PageInkDrawingCache) {
    self.window = window; self.material = material; self.inkWindow = inkWindow; self.ink = ink
  }
  public func frozenForPresentation() -> any NotebookPagePresentationSource {
    Self(window: window, material: material, inkWindow: inkWindow, ink: .init(source: inkSource.source))
  }

  /// The background reader can acknowledge an accepted local cut without
  /// replacing its installed roots. Only bounded typed bodies are compared;
  /// the new snapshot, coverage, causal sources and history remain authoritative.
  public func retainingPresentation(from previous: NotebookPageMaterialSource) -> Self {
    guard id == previous.id, size == previous.size, materialCoverage == previous.materialCoverage else { return self }
    let currentInk = inkSource, priorInk = previous.inkSource
    let sameInk = currentInk.stamp == priorInk.stamp
      && currentInk.preparedDrawing.map { $0 == priorInk.preparedDrawing } == true
    let sameMaterial = window.elements == previous.window.elements
      && window.dependencies == previous.window.dependencies
      && window.sources == previous.window.sources && window.sourceOrder == previous.window.sourceOrder
      && window.graphicPresentation == previous.window.graphicPresentation
      && currentInk.preparedElementErasures == priorInk.preparedElementErasures
    return Self(window: window, material: sameMaterial ? previous.material : material,
      inkWindow: inkWindow, ink: sameInk ? previous.ink : ink)
  }
  public func referenceRevision(elementID: String? = nil) throws -> String {
    if let elementID {
      guard let element = element(id: elementID) else { throw CollaborationError("target_missing", "Элемент листа отсутствует.") }
      return try collaborationHash(JSONValue.encode(element).setting("frame", nil))
    }
    return try inkWindow.referenceBasis.revision(source: inkSource)
  }
  public func graphicGraph() -> NotebookGraphicGraph { window.graphicGraph }
  public func element(id: String) -> AgentElement? { window.source(for: id)?.page }
  public func nativeElementSource(id: String) -> NotebookNativeElementSource? { window.source(for: id) }
  public func elementIdentityStamp(_ id: String) -> VersionStamp? {
    guard let source = nativeElementSource(id: id), source.page != nil else { return nil }
    return source.versions?[fieldKey(["elements", collaborationIdentity(id), "id"])]?.stamp ?? agentStamp
  }
  public func programStateBasis(_ id: String) -> NotebookProgramStateBasis? {
    guard let source = nativeElementSource(id: id), source.page?.kind == .web else { return nil }
    return .init(elementID: source.id, versions: source.versions ?? [:], fallback: agentStamp)
  }
  public func interactionElements(ids: Set<String>, includingIdentityAliases: Bool = false) -> [AgentElement] {
    let keys = Set(ids.map(collaborationIdentity))
    return window.sourceOrder.compactMap { id in keys.contains(collaborationIdentity(id)) ? element(id: id) : nil }
  }
  public func displayElements(graphicIDs: Set<String>) -> [AgentElement] {
    let keys = Set(graphicIDs.map(collaborationIdentity))
    return elements.filter { $0.graphic == nil || keys.contains(collaborationIdentity($0.id)) }
  }
  public func prepareLiveInkChange(_ mutation: PageInkMutation, stamp: VersionStamp) throws -> PreparedPageInkChange {
    let source = inkSource
    guard let prepared = source.preparedProjection else { throw CollaborationError("ink_not_ready", "Рукопись страницы ещё готовится.") }
    return try source.prepareChange(pageID: id, mutation: mutation, stamp: stamp, projection: prepared,
      sequenceFrontier: inkWindow.sequenceFrontier, requiresRetainedActions: true)
  }
  @discardableResult public func publishLiveInkChange(_ change: PreparedPageInkChange) -> Bool {
    guard change.pageID == id else { return false }
    return ink.publish(change)
  }
}
