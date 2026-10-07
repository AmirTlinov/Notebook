import Foundation
import Darwin
@testable import NotebookCore

// Pure Core snapshots only. No store, helper, device, or installed content.
private let actor = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let initial = VersionStamp(counter: 1, actor: actor)
private let successor = VersionStamp(counter: 2, actor: actor)

private func emit(_ value: [String: JSONValue]) throws {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  FileHandle.standardOutput.write(try encoder.encode(JSONValue.object(value)))
  FileHandle.standardOutput.write(Data([10]))
}

private func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }

private func shapes(_ count: Int) -> JSONValue {
  .object(["elements": .array((0..<count).map { index in
    .object(["id": .string("shape/\(index)~"), "kind": .string("graphic"), "source": .string(""),
      "frame": .object(["x": .number(Double(index)), "y": .number(0), "width": .number(20), "height": .number(20)]),
      "graphic": .object(["shape": .string("polygon"), "color": .string("black"), "lineWidth": .number(1),
        "vertices": .array([.object(["x": .number(0), "y": .number(0)]), .object(["x": .number(20), "y": .number(20)])]),
        "connection": .object(["start": .object(["point": .number(0)]), "end": .object(["point": .number(20)])])])])
  })])
}

private func changed(_ value: JSONValue, all: Bool) -> JSONValue {
  var elements = value["elements"]!.arrayValues
  for index in elements.indices where all || index == 0 {
    elements[index] = elements[index].setting("source", .string("edit"))
  }
  return value.setting("elements", .array(elements))
}

private func flatFields(_ count: Int, changed: Bool) -> JSONValue {
  .object(Dictionary(uniqueKeysWithValues: (0..<count).map { index in
    ("field\(index)", .number(Double(index + (changed ? 1 : 0))))
  }))
}

private struct State: Codable {
  var value: JSONValue
  var metadata: CollaborativeContent
  var stamp: VersionStamp
  func merged(_ other: Self) throws -> Self {
    let result = try CollaborativeContent.merge(local: value, incoming: other.value,
      localState: metadata, incomingState: other.metadata, localStamp: stamp, incomingStamp: other.stamp)
    return .init(value: result.value, metadata: result.state, stamp: max(stamp, other.stamp))
  }
  func edited(to next: JSONValue, stamp: VersionStamp, human: Bool) -> Self {
    var metadata = metadata
    metadata.record(before: value, after: next, beforeStamp: self.stamp, stamp: stamp, human: human)
    return .init(value: next, metadata: metadata, stamp: stamp)
  }
}

private func semantics() throws {
  let graphic: JSONValue = .object(["shape": .string("connector"), "color": .string("black"),
    "connection": .object(["start": .object(["point": .number(3)]), "end": .object(["point": .number(4)]),
      "bend": .number(5), "routing": .string("curved")])])
  let item: JSONValue = .object(["id": .string("a/~"), "source": .string("original"), "css": .string("black"), "graphic": graphic])
  let sibling: JSONValue = .object(["id": .string("a/~~"), "source": .string("untouched")])
  let file: JSONValue = .object(["id": .string("a/~"), "path": .string("main.tex"), "source": .string("file")])
  let base: JSONValue = .object(["elements": .array([item, sibling]), "files": .array([file]), "title": .string("exact")])
  var metadata = CollaborativeContent(); metadata.materializeVersions(in: base, fallback: initial)
  let start = State(value: base, metadata: metadata, stamp: initial)
  let removal = start.edited(to: base.setting("elements", .array([sibling])).setting("files", .array([])),
    stamp: .init(counter: 2, actor: other), human: false)
  let clearedGraphic = graphic.setting("connection", graphic["connection"]!.setting("bend", nil))
  let adoptedItem = item.setting("source", .string("human")).setting("css", nil).setting("graphic", clearedGraphic)
  let edit = start.edited(to: base.setting("elements", .array([adoptedItem, sibling]))
    .setting("files", .array([file.setting("source", .string("human file"))])), stamp: successor, human: true)
  let inserted: JSONValue = .object(["id": .string("concurrent"), "source": .string("new")])
  let insertion = start.edited(to: base.setting("elements", .array([inserted, item, sibling])),
    stamp: .init(counter: 2, actor: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!), human: true)
  var snapshots: [JSONValue] = []
  for variants in [[start, removal, edit], [insertion, removal, edit]] {
    for order in [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]] {
      let a = variants[order[0]], b = variants[order[1]], c = variants[order[2]]
      let left = try a.merged(b).merged(c), right = try a.merged(b.merged(c))
      precondition(left.value == right.value && left.metadata == right.metadata)
      precondition(left.value["elements"]!.arrayValues.contains(adoptedItem))
      precondition(left.value["files"] == edit.value["files"])
      for replay in variants {
        let repeated = try left.merged(replay)
        precondition(repeated.value == left.value && repeated.metadata == left.metadata)
      }
      // An inverse is another causal write, including a missing/non-displayed head.
      let undone = left.edited(to: start.value, stamp: .init(counter: 3, actor: actor), human: true)
      let replayed = try undone.merged(left).merged(removal).merged(edit)
      precondition(replayed.value == start.value)
      let cold = try JSONValue.encode(left.metadata).decode(CollaborativeContent.self)
      precondition(cold == left.metadata)
      snapshots += [try .encode(left), try .encode(undone), try .encode(replayed)]
    }
  }
  // A higher-priority human alternative survives hidden, then becomes visible
  // when a causal successor removes the previously displayed head.
  let x = ContentFieldVersion(stamp: .init(counter: 10, actor: actor), human: true)
  let z = ContentFieldVersion(stamp: .init(counter: 9, actor: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!), human: true)
  let y = ContentFieldVersion(stamp: .init(counter: 11, actor: other), human: false,
    observed: [actor.uuidString.lowercased(): 10, other.uuidString.lowercased(): 11])
  let states = [x, y, z].enumerated().map { index, version in
    State(value: .object(["text": .string(["a", "b", "c"][index])]),
      metadata: .init(fields: ["text": version]), stamp: version.stamp)
  }
  for order in [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]] {
    let joined = try states[order[0]].merged(states[order[1]]).merged(states[order[2]])
    precondition(joined.value["text"] == .string("c"))
    snapshots.append(try .encode(joined))
  }
  try emit(["phase": .string("semantics"), "snapshots": .array(snapshots)])
}

let arguments = CommandLine.arguments
if arguments.count == 2 && arguments[1] == "semantics" { try semantics(); exit(0) }
guard arguments.count >= 3, let count = Int(arguments[2]), count > 0 else {
  fatalError("Usage: causal-content-probe semantics | merge-shapes/record-sparse/record-all/merge-fields COUNT [timeout-seconds]")
}
let operation = arguments[1]
let timeout = arguments.count > 3 ? UInt32(arguments[3]) ?? 60 : 60
let before = operation == "merge-fields" ? flatFields(count, changed: false) : shapes(count)
let after = operation == "merge-fields" ? flatFields(count, changed: true) : changed(before, all: operation != "record-sparse")
var metadata = CollaborativeContent(); metadata.materializeVersions(in: before, fallback: initial)
let fieldCount = metadata.fields.count
try emit(["phase": .string("ready"), "operation": .string(operation), "objects": .number(Double(operation == "merge-fields" ? 0 : count)),
  "fields": .number(Double(fieldCount)), "timeoutSeconds": .number(Double(timeout))])
signal(SIGALRM) { _ in _exit(124) }; alarm(timeout)
var usageBefore = rusage(); getrusage(RUSAGE_SELF, &usageBefore)
let began = DispatchTime.now().uptimeNanoseconds
let value: JSONValue
switch operation {
case "record-sparse", "record-all":
  metadata.record(before: before, after: after, beforeStamp: initial, stamp: successor, human: true)
  value = after
case "merge-shapes", "merge-fields":
  // Concurrent complete snapshots exercise both frontiers and materialization.
  let result = try CollaborativeContent.merge(local: before, incoming: after,
    localState: metadata, incomingState: nil, localStamp: initial, incomingStamp: .init(counter: 2, actor: other))
  metadata = result.state; value = result.value
default: fatalError("Unknown operation")
}
let duration = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
var usageAfter = rusage(); getrusage(RUSAGE_SELF, &usageAfter); alarm(0)
precondition(metadata.fields.count == fieldCount && value == after)
try emit(["phase": .string("complete"), "operation": .string(operation), "count": .number(Double(count)),
  "fields": .number(Double(fieldCount)), "wallSeconds": .number(duration),
  "userCPUSeconds": .number(seconds(usageAfter.ru_utime) - seconds(usageBefore.ru_utime)),
  "systemCPUSeconds": .number(seconds(usageAfter.ru_stime) - seconds(usageBefore.ru_stime)),
  "peakRSSBytes": .number(Double(usageAfter.ru_maxrss))])
