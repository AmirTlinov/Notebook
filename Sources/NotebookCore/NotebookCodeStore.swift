import Foundation

func codeFragmentFile(_ id: UUID) -> String { "code-fragments/" + id.uuidString.lowercased() + ".json" }

public struct NotebookCodeAnnotation: Codable, Equatable, Sendable {
  public let fragment: NotebookCodeFragment
  public let ink: SpatialInkJournal
  public init(fragment: NotebookCodeFragment, ink: SpatialInkJournal) { self.fragment = fragment; self.ink = ink }
  public func reference() throws -> CollaborationReference {
    let target = CollaborationTarget(kind: .codeFragment, id: fragment.id)
    return try .init(target: target, region: fragment.region,
      revision: NotebookStore.referenceRevision(target: target, files: sourceFiles()), label: fragment.file.path)
  }
  func sourceFiles() throws -> [String: JSONValue] {
    [codeFragmentFile(fragment.id): try .encode(fragment), "spatial-ink.json": try .encode(ink)]
  }
}

extension NotebookStore {
  public func codeFragment(_ id: UUID) throws -> NotebookCodeFragment? {
    try readTransaction { _ in try storedValue(codeFragmentFile(id))?.decode(NotebookCodeFragment.self) }
  }

  /// Immutable material is captured automatically with the first contact. Both
  /// its address and the measured UUID enter the ordinary delivery transaction.
  public func commitCodeInk(fragment: NotebookCodeFragment, command: NotebookSpatialInkCommand) throws -> NotebookSpatialInkResult {
    guard fragment.isValid else { throw NotebookStorageError.invalidTransaction("reviewed code") }
    return try commandTransaction {
      if case .append(let action, _) = command {
        guard action.spans.allSatisfy({ $0.surface == .codeFragment(fragment.id) }) else {
          throw NotebookStorageError.invalidTransaction("code contact owner")
        }
      } else {
        let address = "spatial-ink.json#/actions/@" + command.expectedResult.actionID.uuidString.lowercased()
        guard try currentSQL!.rows("SELECT kind,owner_id FROM ink_surfaces WHERE address=?", [.text(address)]).allSatisfy({ $0[0].text == SurfaceKind.codeFragment.rawValue && $0[1].text == fragment.id.uuidString.lowercased() }) else {
          throw NotebookStorageError.invalidTransaction("code undo owner")
        }
      }
      try publishCodeFragment(fragment)
      return try commitSpatialInk(command)
    }
  }

  public func captureCodeFragment(_ fragment: NotebookCodeFragment) throws {
    guard fragment.isValid else { throw NotebookStorageError.invalidTransaction("reviewed code") }
    try commandTransaction { try publishCodeFragment(fragment) }
  }

  private func publishCodeFragment(_ fragment: NotebookCodeFragment) throws {
    let file = codeFragmentFile(fragment.id), value = try JSONValue.encode(fragment)
    if let current = try storedValue(file) {
      guard current == value else { throw NotebookStorageError.transactionConflict }
    } else { try publishRecords(writes: [file: value]) }
  }

  /// An indexed file owns its review fragments even if its Mac is unavailable.
  /// The caller pages the list; loading a file never loads other files' ink.
  public func codeFragments(file: NotebookFileAddress, after: UUID? = nil, limit: Int = 64) throws -> [NotebookCodeFragment] {
    guard file.isValid, (1...64).contains(limit) else { throw NotebookStorageError.limitExceeded("code_fragments") }
    return try readTransaction { _ in
      try currentSQL!.rows("SELECT address FROM code_fragment_files WHERE file_id=? AND fragment_id>? ORDER BY fragment_id LIMIT ?",
        [.text(file.id), .text(after?.uuidString.lowercased() ?? ""), .integer(Int64(limit))]).map {
          guard let value = try storedValue(String($0[0].text!.dropLast())) else { throw NotebookStorageError.corruptRecord("code fragment") }
          return try value.decode(NotebookCodeFragment.self)
        }
    }
  }
  public func codeAnnotation(_ id: UUID) throws -> NotebookCodeAnnotation? {
    try readTransaction { _ in
      guard let fragment = try codeFragment(id) else { return nil }
      return try .init(fragment: fragment, ink: readSpatialInk(surfaces: [.codeFragment(id)]))
    }
  }

  /// The exact material shown for discussion is sealed before the chat job.
  /// Later file or ink changes cannot rewrite this SharedContext's evidence.
  public func discussCode(_ annotations: [NotebookCodeAnnotation], references: [CollaborationReference],
    images: [UUID: AgentPinnedImage], unavailable: [UUID: String] = [:], actor: UUID) throws -> SharedContextAppend {
    try commandTransaction {
      guard (1...32).contains(annotations.count), references.count == annotations.count else { throw NotebookStorageError.invalidTransaction("code attention count") }
      for (annotation, reference) in zip(annotations, references) {
        guard annotation.fragment.isValid, reference.target == CollaborationTarget(kind: .codeFragment, id: annotation.fragment.id),
          reference.region == annotation.fragment.region else { throw NotebookStorageError.invalidTransaction("code attention") }
        try publishCodeFragment(annotation.fragment)
      }
      let context = try appendContext(references: references, author: .human, actor: actor, select: true)
      let sources = try zip(annotations, references).map { annotation, reference in
        try AgentPinnedSource.capture(requestID: context.id, reference: reference, files: annotation.sourceFiles())
          .withVisual(images[reference.id], unavailable: unavailable[reference.id])
      }
      try saveAttentionEvidence(sources, contextID: context.id)
      return context
    }
  }
}
