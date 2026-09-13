import Foundation
import Testing
@testable import NotebookCore

struct NotebookPresentationTests {
  let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><circle cx=\"50\" cy=\"50\" r=\"30\" fill=\"none\" stroke=\"indigo\"/></svg>"

  @Test func svgAcceptsVectorsButNotExecutableOrExternalContent() {
    #expect(NotebookPresentationSVG.isValid(svg))
    for source in ["<html/>", "<svg><script>alert(1)</script></svg>",
      "<svg onload=\"alert(1)\"/>", "<svg><foreignObject><div/></foreignObject></svg>",
      "<svg><image href=\"https://example.com\"/></svg>", "<svg><use href=\"file:///tmp/a.svg#x\"/></svg>",
      "<!DOCTYPE svg [<!ENTITY x 'hello'>]><svg>&x;</svg>"] {
      #expect(!NotebookPresentationSVG.isValid(source))
    }
  }

  @Test func boundedScriptRoundTripsWithoutAStoredContentCommand() throws {
    let region = NotebookPresentationRegion(origin: .zero, width: 100, height: 80)
    let request = NotebookPresentationRequest(id: UUID(), view: .init(deviceID: UUID(), sessionID: UUID(), sequence: 3),
      steps: [.init(focus: region, svg: svg, bounds: region)])
    #expect(request.isValid)
    let packet = NotebookTransportPacket(sequence: 1, message: .transient(.presentation(.play(request, expiresAt: Date().addingTimeInterval(5)))))
    let bytes = try NotebookTransportFraming.encode(packet)
    #expect(try JSONDecoder().decode(NotebookTransportPacket.self, from: bytes.dropFirst(4)) == packet)
    var command = NotebookCommand(command: .presentation); command.presentation = request
    #expect(!command.changesStore)
    #expect(try NotebookIPC.decodeCommand(JSONEncoder().encode(command)).presentation == request)
    command.presentation = nil; command.actionID = request.id; command.cancel = true
    let cancellation = try NotebookIPC.decodeCommand(JSONEncoder().encode(command))
    #expect(cancellation.actionID == request.id && cancellation.cancel == true)
  }

  @Test func emptyLongAndAmbiguousScriptsAreRejected() {
    let view = NotebookPresentationView(deviceID: UUID(), sessionID: UUID(), sequence: 0)
    #expect(!NotebookPresentationRequest(id: UUID(), view: view, steps: []).isValid)
    #expect(!NotebookPresentationStep(camera: .init(), focus: .init(origin: .zero, width: 50, height: 50)).isValid)
    #expect(!NotebookPresentationStep(svg: svg).isValid)
    #expect(!NotebookPresentationStep(duration: .infinity, camera: .init()).isValid)
    #expect(!NotebookPresentationRequest(id: UUID(), view: view, steps: Array(repeating: .init(duration: 10, camera: .init()), count: 7)).isValid)
  }

  @Test func focusUsesTiledWorldCoordinatesAndAVisibleMargin() throws {
    let region = NotebookPresentationRegion(origin: .init(tileX: 20, tileY: -30, localX: 10, localY: 15), width: 400, height: 200)
    let camera = try #require(region.fittedCamera(viewport: .init(x: 800, y: 600)))
    #expect(camera.center == region.origin.offsetBy(x: 200, y: 100))
    #expect(camera.scale == 1.6)
  }

  @Test func presentationDoesNotReplaceContactPresenceOrChatTransportSlots() throws {
    let region = NotebookPresentationRegion(origin: .zero, width: 100, height: 80)
    let request = NotebookPresentationRequest(id: UUID(), view: .init(deviceID: UUID(), sessionID: UUID(), sequence: 3), steps: [.init(focus: region)])
    var outgoing = NotebookTransportOutgoing()
    try outgoing.enqueue(.transient(.presentation(.play(request, expiresAt: Date().addingTimeInterval(5)))))
    let presence = PresenceEnvelope(sessionID: UUID(), sequence: 3, phase: .settled,
      presence: .init(mode: .board, camera: .init(), viewport: .init(x: 800, y: 600)))
    try outgoing.enqueue(.transient(.presence(presence)))
    #expect(try outgoing.takeNext()?.message == .transient(.presence(presence)))
    guard case .transient(.presentation(.play(let sent, _))) = try outgoing.takeNext()?.message else {
      Issue.record("The presentation must retain its independent bounded slot"); return
    }
    #expect(sent == request)
  }
}
