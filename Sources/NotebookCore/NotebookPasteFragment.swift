import Foundation

/// Prepared native elements. All clipboard formats share the same atomic action path.
public struct NotebookPasteFragment: Codable, Sendable {
  public struct Diagnostic: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case warning, error }
    public let severity: Severity
    public let code: String
    public let sourceID: String?
    public let message: String
  }
  public struct Item: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let parentID: String?
    public let type: String
    public let label: String
  }
  public let items: [Item]
  public let selectedIDs: [String]
  public let elements: [AgentElement]
  public let sourceIDs: [String: String]
  public let diagnostics: [Diagnostic]
  public let size: SpatialPoint
  public let canInsert: Bool

  public init(elements: [AgentElement], size: SpatialPoint) {
    self.elements = elements
    self.size = size
    self.items = elements.map { .init(id: $0.id, parentID: nil, type: $0.kind.rawValue, label: $0.source) }
    self.selectedIDs = elements.map(\.id)
    self.sourceIDs = [:]
    self.diagnostics = []
    self.canInsert = !elements.isEmpty
  }

  init(items: [Item], selectedIDs: [String], elements: [AgentElement], sourceIDs: [String: String],
    diagnostics: [Diagnostic], size: SpatialPoint, canInsert: Bool) {
    self.items = items; self.selectedIDs = selectedIDs; self.elements = elements
    self.sourceIDs = sourceIDs; self.diagnostics = diagnostics; self.size = size; self.canInsert = canInsert
  }

  /// Every paste receives fresh identities. Internal links remain internal;
  /// an imported fragment cannot claim measurements already in the workspace.
  public func reidentified(namespace: UUID = UUID()) throws -> Self {
    try validateTransfer()
    let ids=Dictionary(uniqueKeysWithValues:elements.map { (collaborationIdentity($0.id),NotebookStore.submissionID(namespace,suffix:$0.id).uuidString.lowercased()) })
    let copies=elements.map { element -> AgentElement in
      var copiedGraphic:NotebookGraphic?
      if let graphic=element.graphic {
        var connection=graphic.connection
        for terminal in NotebookGraphicConnection.Terminal.allCases {
          guard var endpoint=terminal == .start ? connection?.start : connection?.end,
            var binding=endpoint.binding else { continue }
          if let replacement=ids[collaborationIdentity(binding.elementID)] { binding.elementID=replacement;endpoint.binding=binding }
          else { endpoint.binding=nil }
          if terminal == .start { connection?.start=endpoint } else { connection?.end=endpoint }
        }
        copiedGraphic = .init(shape:graphic.shape,style:graphic.style,label:graphic.label,
          representation:graphic.representation,visible:graphic.visible,sourceInkIDs:[],
          connection:connection,vertices:graphic.vertices,cornerRadius:graphic.cornerRadius,
          freehand:graphic.freehand,transform:graphic.transform,path:graphic.path,mask:graphic.mask)
      }
      return .init(id:ids[collaborationIdentity(element.id)]!,kind:element.kind,frame:element.frame,
        source:element.source,html:element.html,css:element.css,javaScript:element.javaScript,
        programPackage:element.programPackage,state:element.state,graphic:copiedGraphic,
        textStyle:element.textStyle,parentID:element.parentID.map { ids[collaborationIdentity($0)]! },basis:element.basis)
    }
    return .init(elements:copies,size:size)
  }

  private func validateTransfer() throws {
    guard canInsert,(1...32).contains(elements.count),Set(elements.map(\.id)).count == elements.count,
      Set(elements.map { collaborationIdentity($0.id) }).count == elements.count,
      size.x.isFinite,size.y.isFinite,size.x > 0,size.y > 0,size.x <= 1_000_000,size.y <= 1_000_000 else {
      throw CollaborationError("invalid_fragment","Неполный или слишком большой фрагмент буфера.")
    }
    let byID=Dictionary(uniqueKeysWithValues:elements.map { (collaborationIdentity($0.id),$0) })
    for element in elements {
      try Task.checkCancellation()
      guard element.id.utf16.count <= 120,element.hasValidSource,
        NotebookElementBasis.validLocalFrame(element.frame) else {
        throw CollaborationError("invalid_fragment","Содержимое фрагмента не проходит проверку вставки.")
      }
      // A package hash without its resources cannot be pasted in another
      // workspace. Keep the original until its complete transfer is available.
      guard element.programPackage == nil else {
        throw CollaborationError("incomplete_fragment","Для переноса программы нужны все её ресурсы.")
      }
      var visited:Set<String>=[collaborationIdentity(element.id)],parentID=element.parentID
      while let id=parentID {
        guard visited.insert(collaborationIdentity(id)).inserted,let parent=byID[collaborationIdentity(id)],parent.kind == .group else {
          throw CollaborationError("invalid_fragment","Неполная или циклическая группа в буфере.")
        }
        parentID=parent.parentID
      }
    }
  }

  public func operations(target: CollaborationTarget, offset: SpatialPoint = .init(x:0,y:0),
    worldOrigin: WorldPoint? = nil) throws -> [CollaborationOperation] {
    try validateTransfer()
    guard canInsert, [.page,.board,.cover].contains(target.kind), offset.x.isFinite, offset.y.isFinite,
      abs(offset.x) <= 1_000_000, abs(offset.y) <= 1_000_000,
      target.kind == .board ? worldOrigin?.isValid == true : worldOrigin == nil else {
      throw CollaborationError("import_not_ready", "Выберите поддерживаемые элементы и точную поверхность вставки.")
    }
    return try elements.map { element in
      var values = try JSONValue.encode(element).object
      values.removeValue(forKey:"id")
      values["frame"] = try .encode(PageRect(x:element.frame.x+(element.parentID == nil ? offset.x : 0),y:element.frame.y+(element.parentID == nil ? offset.y : 0),
        width:element.frame.width,height:element.frame.height))
      if let worldOrigin { values["worldOrigin"] = try .encode(element.parentID == nil ? worldOrigin : .zero) }
      return .init(kind:.insertElement,target:target,id:element.id,values:values)
    }
  }
}
