import Foundation

public struct NotebookChatImage: Sendable {
  public let reference: CollaborationReference
  public let image: AgentPinnedImage
  public init(reference: CollaborationReference, image: AgentPinnedImage) { self.reference = reference; self.image = image }
}

extension NotebookStore {
  /// Uses the normal replicated evidence/blob channel, never a large transient
  /// chat packet. This context is not selected or pinned into a future draft.
  public func saveChatImageAttachments(_ images: [NotebookChatImage], author: UUID) throws -> [CodexInputAttachment] {
    guard !images.isEmpty, images.count <= 5, images.reduce(0,{ $0+$1.image.png.count }) <= 4*1024*1024 else {
      throw NotebookStorageError.limitExceeded("chat images")
    }
    for value in images { try value.image.validate(reference:value.reference) }
    return try commandTransaction {
      let context = try appendContext(references:images.map(\.reference),author:.human,actor:author,select:false)
      let sources = try images.map { value in
        let payload: JSONValue = .object(["reference":try .encode(value.reference),"visual":.object(["status":.string("source_pixels")])])
        return AgentPinnedSource(id:value.reference.id,requestID:context.id,reference:value.reference,payload:payload,image:value.image)
      }
      try saveAttentionEvidence(sources,contextID:context.id)
      return images.map { .init(kind:.image,name:"Показано лазером",
        path:"notebook-laser:"+context.id.uuidString+"/"+$0.reference.id.uuidString) }
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
