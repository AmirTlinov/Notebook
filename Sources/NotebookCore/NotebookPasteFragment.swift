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

  public func operations(target: CollaborationTarget, offset: SpatialPoint = .init(x:0,y:0),
    worldOrigin: WorldPoint? = nil) throws -> [CollaborationOperation] {
    guard canInsert, [.page,.board,.cover].contains(target.kind), offset.x.isFinite, offset.y.isFinite,
      abs(offset.x) <= 1_000_000, abs(offset.y) <= 1_000_000,
      target.kind == .board ? worldOrigin?.isValid == true : worldOrigin == nil else {
      throw CollaborationError("import_not_ready", "Выберите поддерживаемые элементы и точную поверхность вставки.")
    }
    return try elements.map { element in
      var values = try JSONValue.encode(element).object
      values.removeValue(forKey:"id")
      values["frame"] = try .encode(PageRect(x:element.frame.x+offset.x,y:element.frame.y+offset.y,
        width:element.frame.width,height:element.frame.height))
      if let worldOrigin { values["worldOrigin"] = try .encode(worldOrigin) }
      return .init(kind:.insertElement,target:target,id:element.id,values:values)
    }
  }
}
