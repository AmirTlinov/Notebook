import Foundation

public struct NotebookChatImage: Sendable {
  public let reference: CollaborationReference
  public let image: AgentPinnedImage
  public init(reference: CollaborationReference, image: AgentPinnedImage) { self.reference = reference; self.image = image }
}

extension NotebookStore {
  /// Uses the normal replicated evidence/blob channel, never a large transient
  /// chat packet. This context is not selected or pinned into a future draft.
  public func saveChatImageAttachments(_ images: [NotebookChatImage], author: UUID, name: String = "Показано указкой",
    existingAttachments: [CodexInputAttachment] = []) throws -> [CodexInputAttachment] {
    guard !images.isEmpty, images.count <= 5, images.reduce(0,{ $0+$1.image.png.count }) <= 4*1024*1024 else {
      throw NotebookStorageError.limitExceeded("chat images")
    }
    for value in images { try value.image.validate(reference:value.reference) }
    return try commandTransaction {
      guard let existing = try resolvedChatImageAttachments(existingAttachments) else {
        throw CollaborationError("attention_pixels_missing", "Изображение выбранного фрагмента не готово. Укажите его снова.")
      }
      let context = try appendContext(references:images.map(\.reference),author:.human,actor:author,select:false)
      let attachments = images.map { CodexInputAttachment(kind:.image,name:name,
        path:"notebook-laser:"+context.id.uuidString+"/"+$0.reference.id.uuidString) }
      let resolved = zip(attachments,images).map { attachment,image in
        CodexInputAttachment(kind:.image,name:attachment.name,path:attachment.path,imagePNG:image.image.png)
      }
      guard CodexInputAttachment.valid(existing + resolved) else { throw NotebookStorageError.limitExceeded("chat images") }
      let sources = try images.map { value in
        let payload: JSONValue = .object(["reference":try .encode(value.reference),"visual":.object(["status":.string("source_pixels")])])
        return AgentPinnedSource(id:value.reference.id,requestID:context.id,reference:value.reference,payload:payload,image:value.image)
      }
      try saveAttentionEvidence(sources,contextID:context.id)
      return attachments
    }
  }

  /// Selected attention and pointing use the same replicated immutable pixels.
  /// Returning addresses keeps the durable input small; Mac resolves them only
  /// after this exact evidence has arrived, before native turn/start.
  public func chatAttentionAttachments(contextID: UUID) throws -> [CodexInputAttachment] {
    try readTransaction { _ in
      guard let entry = try firstHumanContextEntry(contextID), !entry.references.isEmpty else {
        throw CollaborationError("attention_missing", "Указанный фрагмент не найден.")
      }
      // A source-editor or code selection is semantic text, not a physical
      // paper crop. Its exact source remains in attention; never invent pixels.
      let visualReferences = entry.references.filter {
        $0.target.kind != .codeFragment && !($0.target.kind == .document && $0.elementID != nil && $0.pageIndex == nil)
      }
      let attachments = visualReferences.map { reference in
        CodexInputAttachment(kind:.image,name:"Выбранный фрагмент",path:"notebook-laser:"+contextID.uuidString+"/"+reference.id.uuidString)
      }
      // The local submission owner validates all image addresses together,
      // including pointing images, before committing a durable message.
      return attachments
    }
  }

  /// Nil means that the exact frozen evidence is still being delivered. It is
  /// not permission to send a replacement screenshot or omit it silently.
  public func resolvedChatImageAttachments(_ attachments: [CodexInputAttachment]) throws -> [CodexInputAttachment]? {
    try readTransaction { _ in
      var result: [CodexInputAttachment] = []
      for attachment in attachments {
        guard attachment.kind == .image else { result.append(attachment); continue }
        guard let address = attachment.imageReference else { throw NotebookStorageError.invalidTransaction("invalid chat image address") }
        guard let source = try attentionEvidence(contextID:address.contextID,referenceID:address.referenceID) else { return nil }
        guard let image = source.image else { throw NotebookStorageError.invalidTransaction("chat image evidence has no pixels") }
        result.append(.init(kind:.image,name:attachment.name,path:attachment.path,imagePNG:image.png))
      }
      guard CodexInputAttachment.valid(result) else { throw NotebookStorageError.limitExceeded("chat images") }
      return result
    }
  }
}
