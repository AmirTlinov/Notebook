import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookGraphicInteractionTests: XCTestCase {
  func testAgentPearlAppearanceAndExpiredRemount() async throws {
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView:AnyView(EmptyView()))
    window.overrideUserInterfaceStyle = .light
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil }
    let frame = CGRect(x:100,y:220,width:240,height:160), start = Date()
    func content(_ started: Date) -> AnyView {
      AnyView(ZStack(alignment:.topLeading) {
        Color(red:0.993,green:0.987,blue:0.965)
        NotebookGraphicView(graphic:.init(shape:.rectangle,label:"Действие агента"))
          .frame(width:frame.width,height:frame.height).position(x:frame.midX,y:frame.midY)
        NotebookAgentPearl(rect:frame,startedAt:started)
      }.ignoresSafeArea())
    }
    func capture(_ name: String) -> Data? {
      host.view.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds:frame.insetBy(dx:-16,dy:-16)).image { _ in
        host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)
      }
      let attachment = XCTAttachment(image:image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
      return image.pngData()
    }
    host.rootView = content(start)
    try await Task.sleep(for:.milliseconds(200))
    _ = capture("agent-pearl-shown")
    try await Task.sleep(for:.seconds(NotebookAppModel.agentHighlightDuration))
    let expired = capture("agent-pearl-expired")
    host.rootView = content(start)
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(capture("agent-pearl-remounted-expired"),expired,"A remounted expired accent cannot flash again")
  }

  func testHollowSelectionUsesActualPolygonAndKeepsItsChildrenReachable() throws {
    let pageID = UUID(), surface = SurfaceID.page(pageID)
    func element(_ id: String, _ shape: NotebookGraphic.Shape, _ frame: PageRect) -> AgentElement {
      .init(id:id,kind:.graphic,frame:frame,source:"",html:"",graphic:.init(shape:shape))
    }
    let outer = element("outer",.rectangle,.init(x:0,y:0,width:600,height:700))
    let triangle = element("triangle",.triangle,.init(x:100,y:100,width:240,height:240))
    let diamond = element("diamond",.diamond,.init(x:150,y:210,width:80,height:80))
    let child = AgentElement(id:"child",kind:.web,frame:.init(x:175,y:250,width:24,height:20),source:"",html:"<p>x</p>")
    func pick(_ point: SpatialPoint, _ elements: [AgentElement]) -> String? {
      let graph = NotebookGraphicGraph(elements.compactMap { e in e.graphic.map {
        .init(id:e.id,graphic:$0,frame:e.frame,surface:surface,shown:$0.showsGeometry)
      } })
      return NotebookAttentionProjection.pickElement(in:elements,graph:graph,scale:1,viewport:.init(x:834,y:1194),
        project:{ ($0.id,$0.frame,$0.graphic,point) })?.id
    }
    XCTAssertEqual(pick(.init(x:220,y:200),[triangle]),"triangle")
    XCTAssertNil(pick(.init(x:100,y:100),[triangle]),"A polygon is not its bounding rectangle")
    XCTAssertEqual(pick(.init(x:190,y:250),[diamond,triangle,outer]),"diamond","Small inner shape wins even under a later enclosing outline")
    XCTAssertEqual(pick(.init(x:185,y:260),[child,diamond,triangle,outer]),"child")
    let oversized = element("canvas",.rectangle,.init(x:-1000,y:-1000,width:3000,height:3000))
    XCTAssertNil(pick(.init(x:400,y:500),[oversized]),"An enclosing canvas cannot steal empty-paper navigation")
  }

  func testOnlyNewAgentActionsGetAnExpiringPearl() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pearl-\(UUID())")
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let target = CollaborationTarget(kind:.page,id:try XCTUnwrap(model.activePage?.id))
    let store = model.store
    func action(_ id: String) throws -> CollaborationAction {
      .init(summary:id,expected:[.init(target:target,revision:try store.targetContentRevision(target:target))],
        operations:[.init(kind:.insertElement,target:target,id:id,values:["kind":.string("graphic"),"source":.string(""),
          "frame":try .encode(PageRect(x:100,y:100,width:180,height:140)),"graphic":try .encode(NotebookGraphic(shape:.triangle))])])
    }
    _ = try store.applyNativeGraphicAction(action("human"),actor:model.actorID)
    await model.reloadExternalChanges()?.value
    XCTAssertTrue(model.agentHighlightStarts.isEmpty,"A human shape is never an agent highlight")
    let agent = try store.applyCollaborationAction(action("agent"),actor:UUID())
    await model.reloadExternalChanges()?.value
    let started = try XCTUnwrap(model.agentHighlightStarts[agent.id])
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.agentHighlightStarts[agent.id],started,"A metadata refresh must not restart the pulse")
    try await Task.sleep(for:.seconds(NotebookAppModel.agentHighlightDuration+0.2))
    XCTAssertTrue(model.agentHighlightStarts.isEmpty,"Expiry does not need a mounted or visible view")
    await model.reloadExternalChanges()?.value
    XCTAssertTrue(model.agentHighlightStarts.isEmpty)
  }
}
