import Foundation

/// A bounded immutable element cut, including its author frontier. It owns no
/// store, index or writer; the document's existing lookup resolves its addresses.
public struct NotebookElementCaptureSize: Sendable {
  public let bytes:Int
  public let editableBytes:Int
  public let editableCausalBytes:Int
  public let editableCount:Int
}

public struct NotebookElementSourceSnapshot: Sendable {
  private struct Entry:Sendable {
    let page:AgentElement?
    let spatial:SpatialElement?
    let versions:[String:ContentFieldVersion]?
  }
  private enum Source:Sendable {
    case page(PageElementProjection,CollaborativeContent?)
    case spatial([SpatialElement],BoardElementLookup,CollaborativeContent?)
    case captured([String:Entry],[String],NotebookElementCaptureSize)
  }
  private let source:Source
  public var captureSize:NotebookElementCaptureSize? {
    guard case .captured(_,_,let size)=source else {return nil};return size
  }
  init(page:PageDocument) { source = .page(page.elementProjection,page.collaboration) }
  init(elements:[SpatialElement],lookup:BoardElementLookup,metadata:CollaborativeContent?) {
    source = .spatial(elements,lookup,metadata)
  }
  private init(source:Source) {self.source=source}

  /// Call with the scene's bounded candidate/dependency closure. The returned
  /// cut retains those bodies only, never the whole page/board or its frontier.
  public func capturing(_ ids:Set<String>)->Self {
    let order=orderedIDs(ids)
    var entries:[String:Entry]=[:],bytes=128,bodyBytes=0,causalBytes=0,editableCount=0
    for id in order {
      let entry:Entry
      switch source {
      case .page(let projection,let metadata):
        entry = .init(page:projection.element(id),spatial:nil,versions:metadata?.elementVersions(id:id))
      case .spatial(let elements,let lookup,let metadata):
        guard let offset=lookup.position(of:id) else {continue}
        entry = .init(page:nil,spatial:elements[offset],versions:metadata?.elementVersions(id:id))
      case .captured(let values,_,_):
        guard let value=values[collaborationIdentity(id)] else {continue};entry=value
      }
      entries[collaborationIdentity(id)]=entry
      let body=NotebookNativeElementSource.retainedPayloadBytes(id:id,page:entry.page,spatial:entry.spatial)
      let full=NotebookNativeElementSource.retainedPayloadBytes(id:id,page:entry.page,spatial:entry.spatial,versions:entry.versions)
      bytes += full+id.utf8.count*4
      if entry.page?.graphic != nil || entry.spatial?.graphic != nil || entry.page?.kind == .group || entry.spatial?.kind == .group {
        bodyBytes += body;causalBytes += full-body;editableCount += 1
      }
    }
    bytes += entries.capacity*(MemoryLayout<String>.stride+MemoryLayout<Entry>.stride+32)
      + order.capacity*MemoryLayout<String>.stride
    return .init(source:.captured(entries,order,.init(bytes:bytes,editableBytes:bodyBytes,
      editableCausalBytes:causalBytes,editableCount:editableCount)))
  }
  public func orderedIDs(_ ids:Set<String>)->[String] {
    switch source {
    case .page(let projection,_): return projection.elements(ids:ids).map(\.id)
    case .spatial(let elements,let lookup,_): return ids.compactMap { lookup.position(of:$0) }.sorted().map { elements[$0].id }
    case .captured(_,let order,_):
      let keys=Set(ids.map(collaborationIdentity));return order.filter {keys.contains(collaborationIdentity($0))}
    }
  }
  public func pageElement(_ id:String)->AgentElement? {
    switch source {
    case .page(let projection,_):return projection.element(id)
    case .captured(let values,_,_):return values[collaborationIdentity(id)]?.page
    case .spatial:return nil
    }
  }
  public func nativeSource(_ id:String,target:CollaborationTarget)->NotebookNativeElementSource {
    let versions:[String:ContentFieldVersion]?
    switch source {
    case .page(_,let metadata),.spatial(_,_,let metadata):versions=metadata?.elementVersions(id:id)
    case .captured(let entries,_,_):versions=entries[collaborationIdentity(id)]?.versions
    }
    return .init(target:target,id:id,page:pageElement(id),spatial:spatialElement(id),versions:versions)
  }
  public func spatialElement(_ id:String)->SpatialElement? {
    switch source {
    case .spatial(let elements,let lookup,_):return lookup.position(of:id).map {elements[$0]}
    case .captured(let values,_,_):return values[collaborationIdentity(id)]?.spatial
    case .page:return nil
    }
  }
}

extension PageDocument {
  public var elementSourceSnapshot:NotebookElementSourceSnapshot { .init(page:self) }
}
