import Foundation

/// A lifted contact writes its one addressed row. Undo changes only the
/// selected action headers; neither command reconstructs the page archive.
public enum NotebookPageInkCommand:Sendable {
  case append(PageInkAction,baseStamp:VersionStamp,stamp:VersionStamp)
  case state([UUID:PageInkVisibility],isActive:Bool,baseStamp:VersionStamp,stamp:VersionStamp)

  var baseStamp:VersionStamp { switch self { case .append(_,let value,_),.state(_,_,let value,_):value } }
  var stamp:VersionStamp { switch self { case .append(_,_,let value),.state(_,_,_,let value):value } }

  public init(_ change:PreparedPageInkChange) {
    switch change.mutation {
    case .append(let action): self = .append(action,baseStamp:change.baseStamp,stamp:change.stamp)
    case .setActive(_,let active): self = .state(change.expectedVisibility,isActive:active,baseStamp:change.baseStamp,stamp:change.stamp)
    }
  }
}

public struct NotebookPageInkResult:Equatable,Sendable { public let stamp:VersionStamp }

extension NotebookStore {
  @discardableResult
  public func commitPageInk(pageID:UUID,command:NotebookPageInkCommand) throws -> NotebookPageInkResult {
    guard command.baseStamp.counter <= VersionStamp.maximumCounter,
      command.stamp.counter <= VersionStamp.maximumCounter else {
      throw NotebookStorageError.invalidTransaction("page ink clock")
    }
    return try commandTransaction {
      if try hasStoredValue("workspace.json"),try ownerItemID(ofPage:pageID) == nil { throw CocoaError(.fileNoSuchFile) }
      let file=pageFile(pageID),pageAddress=file+"#",drawingAddress=pageAddress+"/drawingData",database=currentSQL!
      guard let page=try storedFragments(address:pageAddress,descendants:false).first,
        try page.value["id"]?.decode(UUID.self) == pageID,
        page.value["format"] == .number(Double(PageDocument.formatVersion)),
        let previousStamp=try page.value["drawingStamp"]?.decode(VersionStamp.self),
        previousStamp.counter <= VersionStamp.maximumCounter,
        let drawing=try storedFragments(address:drawingAddress,descendants:false).first,
        drawing.parent == pageAddress,drawing.collection == "drawingData",drawing.member.isEmpty,
        drawing.collections.contains(.init(path:["actions"],kind:.array)) else {
        throw NotebookStorageError.corruptRecord(file)
      }
      var changed=false
      switch command {
      case .append(let action,_,_):
        guard action.isValid,action.sequence > 0 else { throw NotebookStorageError.invalidTransaction("page ink action") }
        let member=action.id.uuidString.lowercased(),address=drawingAddress+"/actions/@"+member
        let previous=try storedFragments(address:address,descendants:false).first
        if previous == nil {
          try recordNativeHistory(.ink([action.id]), domain: .page(pageID), actor: command.stamp.actor)
        }
        let position=previous?.position ?? Int(action.sequence-1)
        let fragments=try NotebookRecordCodec.encode(.encode(action),file:file,address:address,
          parent:drawingAddress,collection:"actions",member:member,position:position)
        // Measurement bodies must exist before an eraser header becomes
        // indexable. The header is the admission row and is therefore last.
        for fragment in fragments.sorted(by:{ ($0.address == address ? 1:0) < ($1.address == address ? 1:0) }) {
          if fragment.address == address,let previous {
            guard previous.parent == drawingAddress,previous.collection == "actions",previous.member == member,
              previous.value.setting("isActive",nil).setting("stateStamp",nil) == fragment.value.setting("isActive",nil).setting("stateStamp",nil),
              previous.collections == fragment.collections else { throw NotebookStorageError.transactionConflict }
            let retained=fragment.replacing(value:fragment.value.setting("isActive",previous.value["isActive"]).setting("stateStamp",previous.value["stateStamp"]))
            changed = try writeFragment(retained,database:database) || changed
          } else { changed = try writeFragment(fragment,database:database) || changed }
        }
      case .state(let expected,let active,_,let stamp):
        guard !expected.isEmpty else { break }
        let desired = PageInkVisibility(isActive:active,stateStamp:stamp)
        for (id,source) in expected {
          let member=id.uuidString.lowercased(),address=drawingAddress+"/actions/@"+member
          guard let previous=try storedFragments(address:address,descendants:false).first,
            previous.parent == drawingAddress,previous.collection == "actions",previous.member == member,
            try previous.value["id"]?.decode(UUID.self) == id,
            [.bool(true),.bool(false)].contains(previous.value["isActive"]) else { throw NotebookStorageError.transactionConflict }
          let accepted = try previous.value.decode(PageInkVisibility.self)
          if accepted == desired { continue } // Exact retry after a committed response was lost.
          guard source.isValid, accepted == source, source.isActive != active,
            source.stateStamp.map({ stamp > $0 }) ?? true else {
            throw CollaborationError("revision_conflict","Состояние штриха изменилось до отмены или повтора.")
          }
          changed = try writeFragment(previous.replacing(value:previous.value.setting("isActive",.bool(active))
            .setting("stateStamp",try .encode(stamp))),database:database) || changed
          try recordNativeHistory(.ink([id]),domain:.page(pageID),actor:stamp.actor,removing:!active)
        }
      }
      let frontier=max(previousStamp,command.stamp)
      let nextStamp:VersionStamp
      if changed && previousStamp != command.baseStamp {
        guard let advanced=frontier.advanced(by:frontier.actor) else { throw NotebookStorageError.limitExceeded("page ink clock") }
        nextStamp=advanced
      } else { nextStamp=frontier }
      if nextStamp != previousStamp {
        try writeFragment(page.replacing(value:page.value.setting("drawingStamp",try .encode(nextStamp))),database:database)
      }
      return .init(stamp:nextStamp)
    }
  }

}
