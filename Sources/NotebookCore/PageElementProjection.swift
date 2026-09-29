import Foundation

/// One disposable projection belongs to an immutable page value. Drawing-only
/// edits share it; changing elements or their claim versions creates a new
/// cache. No revision hash substitutes for source identity or enters storage.
final class PageElementProjectionCache: @unchecked Sendable {
  private let lock=NSLock()
  private var prepared:PageElementProjection?
  init() {}
  private init(prepared:PageElementProjection?) { self.prepared=prepared }
  func value(for page:PageDocument) -> PageElementProjection {
    lock.lock();defer { lock.unlock() }
    if let prepared { return prepared }
    let value=PageElementProjection(page);prepared=value;return value
  }
  /// A program state changes its source value, but no placement or graphic
  /// claim. Keep an already prepared projection without making a cold one.
  func replacingProgramState(with source:[AgentElement]) -> PageElementProjectionCache {
    lock.lock();defer { lock.unlock() }
    return .init(prepared:prepared.map { $0.replacingProgramState(with:source) })
  }
}

struct PageElementProjection: Sendable {
  let graph:NotebookGraphicGraph
  let presentation:NotebookGraphicPresentation
  private let source:[AgentElement]
  private let positions:[String:Int]
  private let nonGraphics:[Int]
  init(_ page:PageDocument) {
    source=page.elements
    positions=Dictionary(page.elements.enumerated().map { (collaborationIdentity($0.element.id),$0.offset) },uniquingKeysWith:{ a,_ in a })
    nonGraphics=page.elements.indices.filter { page.elements[$0].kind != .group && page.elements[$0].graphic == nil }
    presentation = .init(page.elements.compactMap { element in
      guard let graphic=element.graphic else { return nil }
      return .init(id:element.id,graphic:graphic,
        version:page.collaboration?.fields[fieldKey(["elements",collaborationIdentity(element.id),"graphic","sourceInkIDs"])]
          ?? .init(stamp:page.agentStamp,human:true))
    })
    graph=page.makeGraphicGraph(shown:presentation.geometryIDs)
  }
  private init(source:[AgentElement], reusing prepared:Self) {
    self.source=source
    graph=prepared.graph;presentation=prepared.presentation
    positions=prepared.positions;nonGraphics=prepared.nonGraphics
  }
  fileprivate func replacingProgramState(with source:[AgentElement]) -> Self {
    .init(source:source,reusing:self)
  }
  func element(_ id:String) -> AgentElement? { positions[collaborationIdentity(id)].map { source[$0] } }
  func elements(graphicIDs:Set<String>) -> [AgentElement] {
    let visible=graphicIDs.compactMap { positions[collaborationIdentity($0)] }.filter { source[$0].graphic != nil }
    return (nonGraphics+visible).sorted().map { source[$0] }
  }
  func elements(ids:Set<String>) -> [AgentElement] {
    ids.compactMap { positions[collaborationIdentity($0)] }.sorted().map { source[$0] }
  }
}
