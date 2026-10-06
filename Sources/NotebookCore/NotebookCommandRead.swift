import Foundation

/// A validated, immutable command for the observation owner. Store mutations,
/// runtime control and external preparation cannot enter this capability.
public struct NotebookReadCommand: Sendable {
  private let request: NotebookCommand

  public static func accepts(_ kind: NotebookCommand.Kind) -> Bool {
    switch kind {
    case .search, .read, .contexts, .action, .actions, .continuations,
      .referenceStatus, .referenceStatuses, .actionDetails, .reference,
      .delivery, .artifact, .scriptArtifact, .panelRead, .prepareAction: true
    default: false
    }
  }

  public init(_ request: NotebookCommand) throws {
    guard Self.accepts(request.command) else {
      throw CollaborationError("read_command_required", "Наблюдение принимает только чистую команду чтения.")
    }
    switch request.command {
    case .search:
      guard (request.query?.utf8.count ?? 0) <= 2_000 else {
        throw CollaborationError("invalid_query", "Запрос поиска слишком длинный.")
      }
    case .read:
      let queries = request.queries ?? []
      guard queries.count <= 128,
        queries.filter({ $0.kind == .contexts }).count <= 1,
        queries.filter({ $0.kind == .contextEntries }).count <= 1 else {
        throw CollaborationError("resource_limit", "Один срез читает до 128 владельцев, один каталог фрагментов и одну страницу истории.")
      }
    case .action, .continuations, .delivery, .prepareAction:
      guard request.actionID != nil else {
        throw CollaborationError("invalid_reference", "Нужен устойчивый ID владельца.")
      }
      if request.command == .prepareAction, request.fingerprint == nil {
        throw CollaborationError("invalid_action", "Нужна исходная идентичность хода.")
      }
    case .referenceStatus:
      guard request.reference != nil else {
        throw CollaborationError("invalid_reference", "Нужна рассмотренная ссылка.")
      }
    case .referenceStatuses:
      guard let references = request.references, references.count <= 256 else {
        throw CollaborationError("resource_limit", "Один срез проверяет до 256 ссылок.")
      }
    case .reference:
      guard request.target != nil else {
        throw CollaborationError("invalid_reference", "Нужен владелец указания.")
      }
    case .artifact, .scriptArtifact:
      guard request.artifact != nil else {
        throw CollaborationError("invalid_artifact", "Нужен точный адрес изображения.")
      }
    case .panelRead:
      guard request.panelRead != nil else {
        throw CollaborationError("invalid_panel_request", "Нужен адресованный запрос панели.")
      }
    case .actionDetails:
      guard request.actionID != nil || request.actionPage?.section == nil else {
        throw CollaborationError("action_required", "Раздел квитанции требует actionID.")
      }
      if request.actionPage?.section != nil, request.readSnapshots == true, request.actionPage?.actionVersion == nil {
        throw CollaborationError("action_version_required", "Продолжение раздела требует actionVersion исходного результата.")
      }
    default: break
    }
    if [.search, .contexts, .actions, .actionDetails].contains(request.command),
      let limit = request.limit, !(1...100).contains(limit) {
      throw CollaborationError("invalid_limit", "Чтение возвращает от 1 до 100 результатов.")
    }
    self.request = request
  }

  var requestForDispatch: NotebookCommand { request }
}
