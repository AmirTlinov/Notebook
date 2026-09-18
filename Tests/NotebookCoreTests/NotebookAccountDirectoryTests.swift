import Foundation
import Testing
@testable import NotebookCore

struct NotebookAccountDirectoryTests {
  private func device(_ space: UUID, _ platform: NotebookAccountDirectory.Device.Platform,
    id: UUID = UUID(), activation: UUID? = nil) -> NotebookAccountDirectory.Device {
    .init(identity: .init(deviceID: id, workspaceID: space, displayName: platform.rawValue), platform: platform, activation: activation)
  }

  @Test func ownDevicesEstablishOneSharedKeyWithoutInvitations() throws {
    let space = UUID(), mac = device(space, .mac), pad = device(space, .iPad)
    var directory = NotebookAccountDirectory(space: .init(id: space, name: "Workspace"))
    try directory.enroll(mac, retained: [], spaceName: "Mac")
    #expect(directory.credentials(for: mac).isEmpty)
    try directory.enroll(pad, retained: [], spaceName: "iPad")
    let first = try #require(directory.credentials(for: mac).first)
    let second = try #require(directory.credentials(for: pad).first)
    #expect(first.0 == pad); #expect(second.0 == mac)
    #expect(first.1 == second.1); #expect(first.1.secret.count == 32)
    let previous = directory
    try directory.enroll(mac, retained: [first.1], spaceName: "Mac")
    #expect(directory == previous)
  }

  @Test func oneMissingDeviceRecoversItsEstablishedKeyOnlyAfterAccountMembership() throws {
    let space = UUID(), mac = device(space, .mac), pad = device(space, .iPad)
    let key = NotebookAccountDirectory.Pair(id: UUID(), workspaceID: space,
      first: mac.identity.deviceID, second: pad.identity.deviceID, secret: Data(repeating: 7, count: 32))
    var directory = NotebookAccountDirectory(space: .init(id: space, name: "Workspace"))
    try directory.enroll(mac, retained: [key], spaceName: "Mac")
    #expect(directory.credentials(for: mac).isEmpty)
    #expect(directory.credentials(for: pad).isEmpty)
    try directory.enroll(pad, retained: [], spaceName: "iPad")
    #expect(directory.credentials(for: mac).first?.1 == key)
    #expect(directory.credentials(for: pad).first?.1 == key)
  }

  @Test func independentSpacesNeverMergeOrAuthorizeEachOther() throws {
    let first = UUID(), second = UUID(), mac = device(first, .mac), pad = device(second, .iPad)
    var directory = NotebookAccountDirectory(space: .init(id: first, name: "First"))
    try directory.enroll(mac, retained: [], spaceName: "Mac")
    try directory.enroll(pad, retained: [], spaceName: "iPad")
    #expect(directory.defaultSpaceID == first); #expect(directory.spaces.count == 2)
    #expect(directory.credentials(for: mac).isEmpty); #expect(directory.credentials(for: pad).isEmpty)
  }

  @Test func staleRetainedKeyCannotRotateTheAccountOwnedPair() throws {
    let space = UUID(), mac = device(space, .mac), pad = device(space, .iPad)
    var directory = NotebookAccountDirectory(space: .init(id: space, name: "Workspace"))
    try directory.enroll(mac, retained: [], spaceName: "Mac")
    try directory.enroll(pad, retained: [], spaceName: "iPad")
    let saved = try #require(directory.pairs.first)
    let conflict = NotebookAccountDirectory.Pair(id: UUID(), workspaceID: space,
      first: saved.first, second: saved.second, secret: Data(repeating: 9, count: 32))
    try directory.enroll(mac, retained: [conflict], spaceName: "Mac")
    #expect(directory.pairs.first == saved)
  }

  @Test func unregisteredDeviceAndChangedActivationCannotUseAnotherMembership() throws {
    let space = UUID(), mac = device(space, .mac, activation: UUID()), pad = device(space, .iPad)
    var directory = NotebookAccountDirectory(space: .init(id: space, name: "Workspace"))
    try directory.enroll(mac, retained: [], spaceName: "Mac")
    try directory.enroll(pad, retained: [], spaceName: "iPad")
    let replacement = device(space, .mac, id: mac.identity.deviceID, activation: UUID())
    #expect(directory.credentials(for: replacement).isEmpty)
    let key = directory.pairs.first
    try directory.enroll(replacement, retained: [], spaceName: "Mac")
    #expect(directory.credentials(for: mac).isEmpty)
    #expect(directory.pairs.first != key)
    let replacementKey = directory.pairs.first
    try directory.enroll(pad, retained: [try #require(key)], spaceName: "iPad")
    #expect(directory.pairs.first == replacementKey)
  }

  @Test func malformedOrUnboundedDirectoryIsRejected() throws {
    let space = UUID()
    let directory = NotebookAccountDirectory(space: .init(id: space, name: "Workspace"))
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(directory)) as? [String: Any])
    json["format"] = 99
    let invalid = try JSONDecoder().decode(NotebookAccountDirectory.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(throws: (any Error).self) { try invalid.validate() }
    #expect(throws: (any Error).self) {
      try NotebookAccountDirectory(space: .init(id: space, name: "")).validate()
    }
  }
}
