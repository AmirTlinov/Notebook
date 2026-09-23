import CoreGraphics
import Foundation
import ImageIO
import NotebookCore
import SwiftUI
import XCTest
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Notebook

@MainActor final class GroupGraphicRenderingTests: XCTestCase {
  func testTextMeasurementFitsTheCompleteSnapshotAtDifferentWidths() throws {
    let source="Ширина строки меняется, но форма букв и отношения внутри целого сохраняются."
    for width in [160.0,240] {
      for (font,size):(String?,Double) in [(nil,12),(nil,20),(nil,34),("Georgia",20),("Menlo-Regular",20)] {
        let style=NativeTextStyle(fontSize:size,format:.init(fontName:font))
        let fitted=NotebookTextTypography.fittingFrame(source,style:style,in:.init(x:0,y:0,width:width,height:1))
        let renderer=ImageRenderer(content:Text(AttributedString(NotebookTextTypography.attributed(source,style:style)))
          .frame(width:width).fixedSize(horizontal:false,vertical:true))
        renderer.scale=1
        let complete=try XCTUnwrap(renderer.cgImage)
        XCTAssertGreaterThanOrEqual(fitted.height,Double(complete.height),"A measured body must fit every rendered line: \(font ?? "system") \(size) / \(width)")
        XCTAssertLessThanOrEqual(fitted.height,Double(complete.height)+1)
      }
    }
  }

  func testTextWidthGripsFollowLocalAxesAndReflowWithoutStretching() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("text-width-\(UUID())")
    let model=NotebookAppModel(store:NotebookStore(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:.init(width:834,height:1194))
    var page=try XCTUnwrap(model.activePage)
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:50,y:80,width:600,height:750),source:"",html:"",
      basis:.init(size:.init(x:500,y:600),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0)))
    let text=AgentElement(id:"text",kind:.nativeText,frame:.init(x:60,y:60,width:280,height:160),
      source:"Ширина строки меняется, но форма букв и отношения внутри целого сохраняются.",html:"",textStyle:.init(fontSize:20),
      parentID:"whole",basis:.init(size:.init(x:240,y:100),transform:.init(a:-0.8,b:0,c:0.2,d:1,tx:0.8,ty:0)))
    XCTAssertTrue(page.replaceElements([whole,text],actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    let ref=EditableElementReference.page(pageID:page.id,elementID:text.id)
    let original=try XCTUnwrap(page.graphicGraph().placement(text.id)),t=original.transform
    model.selectElement(ref)
    for handle in NotebookElementResizeHandle.textWidth {
      let contact=try XCTUnwrap(model.beginElementManipulation(ref,kind:.resize(handle)))
      let dx=handle.leading ? 80.0 : -80.0
      // Deliberate motion along local y must not change the line width.
      let delta=SpatialPoint(x:t.a*dx+t.c*30,y:t.b*dx+t.d*30)
      model.updateElementManipulation(contact,translation:delta)
      let shown=try XCTUnwrap(model.elementPresentation(ref))
      XCTAssertEqual(shown.placement.localSize.x,160,accuracy:1e-9)
      XCTAssertGreaterThan(shown.localBounds.height,NotebookElementPresentation(text,placement:original).localBounds.height)
      for (a,b) in zip([shown.placement.transform.a,shown.placement.transform.b,shown.placement.transform.c,shown.placement.transform.d],[t.a,t.b,t.c,t.d]) {
        XCTAssertEqual(a,b,accuracy:1e-10,"Width changes layout, never the font's placed axes")
      }
      let before=CGPoint(x:handle.leading ? 240 : 0,y:0).applying(t)
      let after=CGPoint(x:handle.leading ? 160 : 0,y:0).applying(shown.placement.transform)
      XCTAssertEqual(after.x,before.x,accuracy:1e-9);XCTAssertEqual(after.y,before.y,accuracy:1e-9)
      let screen=CGRect(x:90,y:120,width:shown.bounds.width*0.75,height:shown.bounds.height*0.75)
      let grips=try XCTUnwrap(model.textWidthControls(ref,screenFrame:screen,scale:0.75))
      for side in NotebookElementResizeHandle.textWidth {
        let physical=side.point(in:.init(origin:.zero,size:shown.bodySize)).applying(shown.placement.transform)
        let point=grips.point(side)
        XCTAssertEqual(point.x,screen.minX+(physical.x-shown.bounds.minX)*0.75,accuracy:1e-9)
        XCTAssertEqual(point.y,screen.minY+(physical.y-shown.bounds.minY)*0.75,accuracy:1e-9)
        let voiceOver=grips.translation(leading:side.leading,amount:20)
        let local=try XCTUnwrap(shown.placement.bodyVector(.init(x:voiceOver.x/0.75,y:voiceOver.y/0.75)))
        XCTAssertEqual(local.y,0,accuracy:1e-9);XCTAssertEqual(local.x<0,side.leading)
      }
      #if os(iOS)
      let controls=NotebookSelectionControlsView(gate:model.inputGate,contextMenus:NotebookContextMenus())
      controls.frame = .init(x:0,y:0,width:834,height:1194)
      controls.configure(selectionID:model.selectionSession.id,frame:screen,textWidth:grips)
      controls.layoutIfNeeded()
      let access=try XCTUnwrap(controls.accessibilityElements as? [UIAccessibilityElement])
      XCTAssertEqual(access.count,2)
      for (item,side) in zip(access,NotebookElementResizeHandle.textWidth) {
        let point=grips.point(side)
        XCTAssertEqual(item.accessibilityFrameInContainerSpace.midX,point.x,accuracy:1e-9)
        XCTAssertEqual(item.accessibilityFrameInContainerSpace.midY,point.y,accuracy:1e-9)
        XCTAssertTrue(controls.point(inside:point,with:nil))
      }
      controls.uninstall()
      #endif
      if handle == .trailingCenter {
        let projected=CGRect(x:shown.bounds.minX*0.75,y:shown.bounds.minY*0.75,width:shown.bounds.width*0.75,height:shown.bounds.height*0.75)
        let material=AgentOverlayView(page:page,renderingScale:0.75,allowsInteraction:false,inputEnabled:false,
          onRenderReady:{ _ in },onState:{ _,_ in false }).frame(width:834,height:1194)
          .scaleEffect(0.75,anchor:.topLeading).frame(width:760,height:760,alignment:.topLeading)
        #if os(iOS)
        let menus=NotebookContextMenus()
        let content=ZStack(alignment:.topLeading) {
          Color.white;material
          NotebookElementControls(contextMenus:menus,reference:ref,selectionID:model.selectionSession.id,frame:projected,scale:0.75)
        }.frame(width:760,height:760).environment(model)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous=scene.windows.first(where: \.isKeyWindow),window=UIWindow(windowScene:scene)
        let host=UIHostingController(rootView:content)
        window.rootViewController=host;window.makeKeyAndVisible()
        try await Task.sleep(for:.milliseconds(150));host.view.layoutIfNeeded()
        let data=try XCTUnwrap(UIGraphicsImageRenderer(bounds:host.view.bounds).image { _ in
          host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)
        }.pngData())
        window.isHidden=true;window.rootViewController=nil;previous?.makeKey()
        #else
        let content=ZStack(alignment:.topLeading) {
          Color.white;material
          MacElementControls(reference:ref,frame:projected,scale:0.75)
        }.frame(width:760,height:760).environment(model)
        let window=NSWindow(contentRect:.init(x:0,y:0,width:760,height:760),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:content);window.contentView=host;window.orderFront(nil)
        try await Task.sleep(for:.milliseconds(150));host.layoutSubtreeIfNeeded();host.displayIfNeeded()
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        let data=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        window.orderOut(nil);window.contentView=nil;window.close()
        #endif
        let proof=XCTAttachment(data:data,uniformTypeIdentifier:"public.png")
        proof.name="placed-text-width-controls";proof.lifetime = .keepAlways;add(proof)
      }
      XCTAssertEqual(try model.store.loadPage(page.id).element(id:text.id),text,"Pointer samples never persist")
      model.updateElementManipulation(contact,translation:.zero)
      XCTAssertEqual(model.elementPresentation(ref)?.placement,original,"Returning to the grip restores the exact descriptor")
      XCTAssertTrue(model.finishElementManipulation(contact,translation:delta))
      let flushed=await model.finishPendingPersistence();XCTAssertTrue(flushed)
      await model.reloadExternalChanges()?.value
      let saved=try NotebookStore(root:root).loadPage(page.id)
      XCTAssertEqual(saved.element(id:whole.id),whole)
      let written=try XCTUnwrap(saved.element(id:text.id))
      XCTAssertEqual(written.source,text.source);XCTAssertEqual(written.textStyle,text.textStyle)
      XCTAssertEqual(try XCTUnwrap(written.basis).size.x,160,accuracy:1e-9)
      XCTAssertEqual(saved.graphicGraph().placement(text.id),shown.placement)
      model.undoLastSurfaceAction();let undone=await model.finishPendingPersistence();XCTAssertTrue(undone)
      await model.reloadExternalChanges()?.value
      XCTAssertEqual(try model.store.loadPage(page.id).element(id:text.id)?.frame,text.frame)
      XCTAssertEqual(try model.store.loadPage(page.id).element(id:text.id)?.basis,text.basis)
      model.selectElement(ref)
    }
  }

  func testPlacedTextTypingAndFormattingKeepItsLocalAxes() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("placed-text-\(UUID())")
    let model=NotebookAppModel(store:NotebookStore(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:.init(width:834,height:1194))
    var page=try XCTUnwrap(model.activePage)
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:100,y:100,width:400,height:600),source:"",html:"",
      basis:.init(size:.init(x:200,y:200),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0)))
    let text=AgentElement(id:"text",kind:.nativeText,frame:.init(x:30,y:40,width:100,height:160),source:"Исходный текст",html:"",
      parentID:"whole",basis:.init(size:.init(x:240,y:60),transform:.init(a:-1,b:0,c:0,d:1,tx:1,ty:0)))
    XCTAssertTrue(page.replaceElements([whole,text],actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    let ref=EditableElementReference.page(pageID:page.id,elementID:text.id)
    let original=try XCTUnwrap(page.graphicGraph().placement(text.id))
    model.selectElement(ref);model.interactiveElementFocus = .page(pageID:page.id,elementID:text.id)
    var target=try XCTUnwrap(model.selectionSession.nativeText)
    XCTAssertEqual(target.localFrame.width,240,"The displayed outer width is not the editor's layout width")
    XCTAssertEqual(target.basis,text.basis)
    model.measureNativeText(ref,height:108)
    target=try XCTUnwrap(model.selectionSession.nativeText)
    XCTAssertEqual(target.localFrame.height,108)
    let editor=try XCTUnwrap(model.nativeTextEditingPresentation(target))
    func sameAxes(_ actual:CGAffineTransform,_ expected:CGAffineTransform,file:StaticString = #filePath,line:UInt = #line) {
      for (a,b) in zip([actual.a,actual.b,actual.c,actual.d,actual.tx,actual.ty],
        [expected.a,expected.b,expected.c,expected.d,expected.tx,expected.ty]) { XCTAssertEqual(a,b,accuracy:1e-10,file:file,line:line) }
    }
    sameAxes(editor.placement.transform,original.transform)
    model.commitNativeText(reference:ref,text:"Правка внутри преобразованного текста",finish:true,height:108,draftTarget:target)
    let savedTyping=await model.finishPendingPersistence();XCTAssertTrue(savedTyping)
    var saved=try model.store.loadPage(page.id)
    var written=try XCTUnwrap(saved.element(id:text.id))
    XCTAssertEqual(written.basis?.size,.init(x:240,y:108));XCTAssertEqual(written.parentID,"whole")
    XCTAssertEqual(saved.element(id:whole.id),whole)
    sameAxes(try XCTUnwrap(saved.graphicGraph().placement(text.id)).transform,original.transform)
    model.clearSelection();await model.reloadExternalChanges()?.value
    model.selectElement(ref);model.formatNativeText(ref) { $0.bold=true }
    let savedFormatting=await model.finishPendingPersistence();XCTAssertTrue(savedFormatting)
    saved=try model.store.loadPage(page.id);written=try XCTUnwrap(saved.element(id:text.id))
    XCTAssertEqual(written.textStyle?.format?.bold,true);XCTAssertEqual(written.basis?.size.x,240)
    XCTAssertEqual(saved.element(id:whole.id),whole)
    sameAxes(try XCTUnwrap(saved.graphicGraph().placement(text.id)).transform,original.transform)
    model.clearSelection();await model.reloadExternalChanges()?.value
    let shown=try XCTUnwrap(model.elementPresentation(ref))
    let point=CGPoint(x:12,y:12).applying(shown.placement.transform)
    let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
    XCTAssertNil(model.beginToolText(at:.init(x:point.x,y:point.y),address:address,screenScale:1))
    XCTAssertEqual(model.selectionSession.element,ref,"The text tool uses the same inverse placement as ordinary picking")
    model.interactiveElementFocus = .page(pageID:page.id,elementID:text.id)
    let inputTarget=try XCTUnwrap(model.selectionSession.nativeText)
    let inputPlacement=try XCTUnwrap(model.nativeTextEditingPresentation(inputTarget))
    func content(_ placement:NotebookElementPresentation) -> AnyView { AnyView(NotebookPlacedElement(presentation:placement) {
      NotebookNativeTextView(source:inputTarget.source,style:inputTarget.style,reference:ref,isEditing:true,
        onEditingEnded:{},retainedPage:written,ownsEditor:true,draftTarget:inputTarget)
    }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(.white).environment(model)) }
    #if os(iOS)
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first { $0.isKeyWindow },window=UIWindow(windowScene:scene)
    let host=UIHostingController(rootView:content(inputPlacement))
    window.rootViewController=host;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil;previous?.makeKey() }
    func find(_ view:UIView) -> UITextView? {
      if let input=view as? UITextView { return input }
      return view.subviews.lazy.compactMap(find).first
    }
    var found:UITextView?
    for _ in 0..<50 { host.view.layoutIfNeeded();found=find(host.view);if found != nil { break };try await Task.sleep(for:.milliseconds(20)) }
    let input=try XCTUnwrap(found)
    XCTAssertEqual(input.bounds.width,inputTarget.localFrame.width,accuracy:0.01)
    let first=try XCTUnwrap(input.position(from:input.beginningOfDocument,offset:0))
    let second=try XCTUnwrap(input.position(from:input.beginningOfDocument,offset:2))
    let a=input.caretRect(for:first),b=input.caretRect(for:second)
    let pa=CGPoint(x:a.midX,y:a.midY),pb=CGPoint(x:b.midX,y:b.midY)
    let screenA=input.convert(pa,to:window),screenB=input.convert(pb,to:window)
    input.selectedRange = .init(location:2,length:0);input.insertText("!")
    #else
    let previous=NSApp.keyWindow
    let window=NSWindow(contentRect:.init(x:0,y:0,width:800,height:1000),styleMask:[.titled],backing:.buffered,defer:false)
    let host=NSHostingView(rootView:content(inputPlacement))
    window.contentView=host;window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil);window.contentView=nil;previous?.makeKey() }
    func find(_ view:NSView) -> NSTextView? {
      if let input=view as? NSTextView { return input }
      return view.subviews.lazy.compactMap(find).first
    }
    var found:NSTextView?
    for _ in 0..<50 { host.layoutSubtreeIfNeeded();found=find(host);if found != nil { break };try await Task.sleep(for:.milliseconds(20)) }
    let input=try XCTUnwrap(found)
    XCTAssertEqual(input.bounds.width,inputTarget.localFrame.width,accuracy:0.01)
    let layout=try XCTUnwrap(input.layoutManager),container=try XCTUnwrap(input.textContainer)
    layout.ensureLayout(for:container)
    let pa=layout.location(forGlyphAt:0),pb=layout.location(forGlyphAt:2)
    let screenA=input.convert(pa,to:nil),screenB=input.convert(pb,to:nil)
    input.setSelectedRange(.init(location:2,length:0));input.insertText("!",replacementRange:input.selectedRange())
    #endif
    XCTAssertGreaterThan(hypot(pb.x-pa.x,pb.y-pa.y),1,"Two distinct caret positions make the coordinate proof nonempty")
    let expectedA=pa.applying(inputPlacement.placement.transform),expectedB=pb.applying(inputPlacement.placement.transform)
    XCTAssertEqual(abs(screenB.x-screenA.x),abs(expectedB.x-expectedA.x),accuracy:0.5)
    XCTAssertEqual(abs(screenB.y-screenA.y),abs(expectedB.y-expectedA.y),accuracy:0.5)
    let expected=String(inputTarget.source.prefix(2))+"!"+String(inputTarget.source.dropFirst(2))
    for _ in 0..<100 {
      if model.nativeTextTarget(ref)?.source == expected { break }
      try await Task.sleep(for:.milliseconds(20))
    }
    XCTAssertEqual(model.nativeTextTarget(ref)?.source,expected,"The installed native editor publishes its insertion through the same owner")
    let savedInput=await model.finishPendingPersistence();XCTAssertTrue(savedInput)
    let afterInput=try model.store.loadPage(page.id)
    XCTAssertEqual(afterInput.element(id:text.id)?.source,expected)
    XCTAssertEqual(afterInput.element(id:whole.id),whole)
    XCTAssertEqual(afterInput.element(id:text.id)?.basis?.size.x,240)
    sameAxes(try XCTUnwrap(afterInput.graphicGraph().placement(text.id)).transform,original.transform)
    // Capture after the native input/keyboard and accepted edit have settled,
    // in the actual host bounds rather than an oversized offscreen fixture.
    try await Task.sleep(for:.milliseconds(150))
    #if os(iOS)
    host.view.layoutIfNeeded()
    let snapshot=UIGraphicsImageRenderer(size:host.view.bounds.size).pngData { _ in
      host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)
    }
    #else
    host.layoutSubtreeIfNeeded()
    let image=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
    host.cacheDisplay(in:host.bounds,to:image)
    let snapshot=try XCTUnwrap(image.representation(using:.png,properties:[:]))
    #endif
    let proof=XCTAttachment(data:snapshot,uniformTypeIdentifier:"public.png")
    proof.name="placed-native-text-editor";proof.lifetime = .keepAlways;add(proof)
    // A parent-only change keeps the physical editor and its local selection.
    let groupRef=EditableElementReference.page(pageID:page.id,elementID:whole.id)
    XCTAssertTrue(model.performElementOperation(.updateElement,reference:groupRef,
      values:["frame":try .encode(PageRect(x:120,y:130,width:400,height:600))],summary:"Передвинуть целое"))
    let savedWhole=await model.finishPendingPersistence();XCTAssertTrue(savedWhole)
    let movedInput=try XCTUnwrap(model.nativeTextEditingPresentation(try XCTUnwrap(model.selectionSession.nativeText)))
    host.rootView=content(movedInput)
    try await Task.sleep(for:.milliseconds(60))
    #if os(iOS)
    host.view.layoutIfNeeded()
    XCTAssertTrue(find(host.view) === input);XCTAssertEqual(input.selectedRange,.init(location:3,length:0))
    #else
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(find(host) === input);XCTAssertEqual(input.selectedRange(),.init(location:3,length:0))
    #endif
    XCTAssertEqual(input.bounds.width,240,accuracy:0.01)
    XCTAssertEqual(try model.store.loadPage(page.id).element(id:text.id),afterInput.element(id:text.id))
    var rootTarget=NotebookNativeTextTarget(reference:ref,address:.init(surface:.page(page.id),boardID:nil,worldOrigin:nil,
      bounds:.init(x:0,y:0,width:500,height:500)),frame:.init(x:100,y:100,width:120,height:300),source:"root",style:.standard,
      basis:.init(size:.init(x:100,y:60),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0)))
    XCTAssertEqual(rootTarget.maximumBodyHeight,110)
    try rootTarget.resizeBody(width:100,height:110)
    XCTAssertEqual(rootTarget.frame,.init(x:0,y:100,width:220,height:300))
  }

  func testMixedWholeMovesAndScalesWithoutRelayoutOrRestartingItsProgram() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("mixed-whole-runtime-\(UUID())")
    let model=NotebookAppModel(store:NotebookStore(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:.init(width:834,height:1194))
    var page=try XCTUnwrap(model.activePage)
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:100,y:100,width:400,height:400),source:"",html:"",
      basis:.init(size:.init(x:400,y:400)))
    let program=AgentElement(id:"program",kind:.web,frame:.init(x:20,y:20,width:180,height:100),source:"Counter",html:
      "<button id='counter' onclick='this.textContent=Number(this.textContent)+1'>7</button><input id='value' value='retained'>",parentID:whole.id)
    let text=AgentElement(id:"text",kind:.nativeText,frame:.init(x:20,y:150,width:180,height:10),source:"Несколько строк текста внутри общего основания",html:"",
      textStyle:.init(fontSize:20),parentID:whole.id)
    XCTAssertTrue(page.replaceElements([whole,program,text],actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    let content=MixedWholeProgramPage(pageID:page.id).environment(model)
    #if os(iOS)
    let previous=UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first(where: \.isKeyWindow)
    let window=UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host=UIHostingController(rootView:content);window.rootViewController=host;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil;previous?.makeKey() }
    func webViews(_ view:UIView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
    func allWebs() -> [WKWebView] { webViews(host.view) }
    func layout() { host.view.layoutIfNeeded() }
    func rectangle(_ web:WKWebView) -> CGRect { web.convert(web.bounds,to:host.view) }
    #else
    let previous=NSApp.keyWindow,window=NSWindow(contentRect:.init(x:0,y:0,width:834,height:1194),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:content);window.contentView=host;window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil);window.contentView=nil;previous?.makeKey() }
    func webViews(_ view:NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
    func allWebs() -> [WKWebView] { webViews(host) }
    func layout() { host.layoutSubtreeIfNeeded() }
    func rectangle(_ web:WKWebView) -> CGRect { web.convert(web.bounds,to:host) }
    #endif
    let source=agentElementSnapshotSource(program)
    func live() -> [WKWebView] { allWebs().filter { ($0.navigationDelegate as? AgentWebCoordinator)?.hasLiveSource(source) == true } }
    var found:WKWebView?
    let deadline=ContinuousClock.now + .seconds(8)
    repeat {
      layout()
      if let web=live().first,(try? await web.evaluateJavaScript("Boolean(document.getElementById('counter'))")) as? Bool == true { found=web;break }
      try await Task.sleep(for:.milliseconds(20))
    } while ContinuousClock.now<deadline
    let web=try XCTUnwrap(found)
    _ = try await web.evaluateJavaScript("window.runtimeToken='kept';document.getElementById('value').value='typed value';null")
    let ref=EditableElementReference.page(pageID:page.id,elementID:whole.id),textRef=EditableElementReference.page(pageID:page.id,elementID:text.id)
    let textSize=try XCTUnwrap(model.elementPresentation(textRef)).bodySize
    model.selectElement(ref)
    XCTAssertTrue(model.groupAllowsLiveManipulation(ref))
    let bounds=try XCTUnwrap(model.groupManipulationGeometry(ref)).bounds
    XCTAssertGreaterThan(bounds.maxY,260,"Selection includes fitted text beyond its ten-point authored height")
    let move=try XCTUnwrap(model.beginElementManipulation(ref,kind:.move))
    XCTAssertTrue(model.finishElementManipulation(move,translation:.init(x:60,y:80)))
    let movedSaved=await model.finishPendingPersistence();XCTAssertTrue(movedSaved);await model.reloadExternalChanges()?.value
    let moved=try model.store.loadPage(page.id)
    XCTAssertEqual(moved.element(id:text.id),text);XCTAssertEqual(moved.element(id:program.id),program)
    for rotated in [false,true] {
      if rotated {
        XCTAssertTrue(model.transformSelectedGroup(radians:.pi/6,scale:1.2))
        let saved=await model.finishPendingPersistence();XCTAssertTrue(saved);await model.reloadExternalChanges()?.value
        XCTAssertNotEqual(try model.store.loadPage(page.id).element(id:whole.id)?.basis,moved.element(id:whole.id)?.basis,
          model.actionCue ?? "The rotation must actually commit, not merely handle a denied command")
      }
      let expected=try XCTUnwrap(model.elementPresentation(.page(pageID:page.id,elementID:program.id))).bounds
      let ready=ContinuousClock.now + .seconds(3)
      repeat {
        layout()
        if abs(rectangle(web).width-expected.width)<0.5 && abs(rectangle(web).height-expected.height)<0.5 { break }
        try await Task.sleep(for:.milliseconds(20))
      } while ContinuousClock.now<ready
      XCTAssertEqual(live().count,1);XCTAssertTrue(live().first === web,"A whole pose must not mount a second program")
      XCTAssertEqual(web.bounds.width,180,accuracy:0.01);XCTAssertEqual(web.bounds.height,100,accuracy:0.01)
      XCTAssertEqual(rectangle(web).width,expected.width,accuracy:0.5);XCTAssertEqual(rectangle(web).height,expected.height,accuracy:0.5)
      XCTAssertEqual(try XCTUnwrap(model.elementPresentation(textRef)).bodySize,textSize,"Moving/scaling the whole does not reflow its text")
      let retained=try await web.evaluateJavaScript("window.runtimeToken==='kept'&&document.getElementById('value').value==='typed value'") as? Bool
      XCTAssertEqual(retained,true)
      let count=try await web.evaluateJavaScript("document.getElementById('counter').click();Number(document.getElementById('counter').textContent)") as? Int
      XCTAssertEqual(count,rotated ? 9 : 8)
      if rotated {
        #if os(iOS)
        let png=try XCTUnwrap(UIGraphicsImageRenderer(bounds:host.view.bounds).image { _ in
          host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)
        }.pngData())
        #else
        window.displayIfNeeded();host.layoutSubtreeIfNeeded()
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
        let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        #endif
        let proof=XCTAttachment(data:png,uniformTypeIdentifier:"public.png");proof.name="mixed-whole-live-program-rotated";proof.lifetime = .keepAlways;add(proof)
      }
    }
    let changed=try model.store.loadPage(page.id)
    XCTAssertEqual(changed.element(id:text.id),text);XCTAssertEqual(changed.element(id:program.id),program)
    let rotation=try XCTUnwrap(model.store.collaborationActions(afterID:nil).first { $0.action.summary == "Повернуть группу" })
    XCTAssertEqual(rotation.action.operations.map(\.id),[whole.id])
    model.undoCollaboration(rotation.id)
    let undone=await model.finishPendingPersistence();XCTAssertTrue(undone);await model.reloadExternalChanges()?.value
    XCTAssertEqual(try model.store.loadPage(page.id).elements,moved.elements)
    XCTAssertEqual(try NotebookStore(root:root).loadPage(page.id).elements,moved.elements)
    XCTAssertEqual(live().count,1);XCTAssertTrue(live().first === web)
  }

  func testMixedBodiesSharePlacementButRetainLocalLayoutAndPixels() async throws {
    let actor=UUID(),pageID=UUID()
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:40,y:30,width:240,height:600),source:"",html:"",
      basis:.init(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0)))
    let web=AgentElement(id:"web",kind:.web,frame:.init(x:10,y:20,width:100,height:60),source:"control",html:"<button>Press</button>",parentID:"whole")
    let text=AgentElement(id:"text",kind:.nativeText,frame:.init(x:10,y:90,width:180,height:24),source:"Текст сохраняет ширину",html:"",parentID:"whole")
    let page=PageDocument(id:pageID,size:.init(width:400,height:800),actor:actor,elements:[whole,web,text])
    let graph=page.graphicGraph(),placement=try XCTUnwrap(graph.placement(web.id))
    let shown=NotebookElementPresentation(web,placement:placement)
    XCTAssertEqual(shown.bounds,CGRect(x:120,y:60,width:120,height:300))
    XCTAssertEqual(shown.bodySize,CGSize(width:100,height:60));XCTAssertEqual(shown.maximumScale,3)
    let textPresentation=NotebookElementPresentation(text,placement:try XCTUnwrap(graph.placement(text.id)))
    XCTAssertEqual(textPresentation.bodySize.width,180)
    let moved=graph.projecting(placements:["whole":.init(frame:.init(x:80,y:70,width:240,height:600),basis:whole.basis,isGroup:true)])
    XCTAssertTrue(moved.sharesSource(with:graph))
    XCTAssertEqual(try XCTUnwrap(moved.placement(web.id)).bounds,shown.bounds.offsetBy(dx:40,dy:40))
    XCTAssertEqual(moved.source(text.id),graph.source(text.id))
    let local=agentElementSnapshotSource(web),resources=SceneRenderResources()
    let bitmap=try XCTUnwrap(CGContext(data:nil,width:400,height:240,bitsPerComponent:8,bytesPerRow:1600,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.setFillColor(CGColor(gray:0,alpha:1));bitmap.fill(.init(x:0,y:0,width:400,height:240))
    let cg=try XCTUnwrap(bitmap.makeImage())
    #if os(iOS)
    let image=UIImage(cgImage:cg,scale:4,orientation:.up)
    #else
    let image=NSImage(cgImage:cg,size:shown.bodySize)
    #endif
    XCTAssertTrue(resources.store(image,for:local))
    let raster=try XCTUnwrap(resources.retainRaster(for:local,minimumScale:3));defer { raster.release() }
    let result=try await PageCompositionRenderer.render(page,scale:1,resources:resources) { requested in
      XCTAssertEqual(requested,local,"The ancestor is not another WebKit source or layout width")
      return raster
    }
    let body=try pixels(result.png)
    XCTAssertTrue(dark(body,180,150));XCTAssertTrue(dark(body,180,285));XCTAssertFalse(dark(body,60,70))
    func pick(_ point:SpatialPoint) -> String? {
      NotebookAttentionProjection.pickElement(in:page.elements,graph:graph,scale:1,viewport:.init(x:400,y:800),presentation:{ .init($0,placement:$1) },
        project:{ ($0.id,$0.graphic,point) })?.id
    }
    XCTAssertEqual(pick(.init(x:180,y:150)),web.id);XCTAssertNil(pick(.init(x:300,y:70)))
    XCTAssertGreaterThan(textPresentation.bodySize.height,text.frame.height)
    let lastLine=CGPoint(x:5,y:textPresentation.localBounds.maxY-2).applying(textPresentation.placement.transform)
    XCTAssertEqual(pick(.init(x:lastLine.x,y:lastLine.y)),text.id,"Picking keeps fitted text below the authored minimum height")
    let proof=XCTAttachment(data:result.png,uniformTypeIdentifier:"public.png")
    proof.name="mixed-bodies-rotated";proof.lifetime = .keepAlways;add(proof)
    XCTAssertEqual(page.elements,[whole,web,text])
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("mixed-body-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),header=try store.initializeWorkspace(actor:actor,pageSize:page.size)
    let target=CollaborationTarget(kind:.board,id:header.rootBoardID)
    let origin=WorldPoint(tileX:1_000_000_000_000,tileY:-1_000_000_000_000,localX:3,localY:7)
    let operations=try page.elements.map { element in
      var values:[String:JSONValue] = ["kind":try .encode(element.kind),"source":.string(element.source),"html":.string(element.html),
        "frame":try .encode(element.frame),"worldOrigin":try .encode(element.parentID == nil ? origin : .zero)]
      if let parent=element.parentID { values["parentID"] = .string(parent) }
      if let basis=element.basis { values["basis"] = try .encode(basis) }
      return CollaborationOperation(kind:.insertElement,target:target,id:element.id,values:values)
    }
    _ = try store.applyNativeElementEdits(operations,summary:"Смешанное целое",sources:operations.map { .init(target:target,id:$0.id!) },actor:actor)
    let workspace=try store.loadIndex(),hierarchy=try store.loadBoard(items:workspace.items),current=try store.workspaceHeader()
    let index=WorkspaceSceneIndex(workspace:workspace,hierarchy:hierarchy,paperSizes:[:])
    let sources=[SceneCompositionSource(store:store,revision:current.cursor,workspaceID:current.workspaceID),
      SceneCompositionSource(index:index,hierarchy:hierarchy,journal:.init(stamp:workspace.stamp))]
    let presence=SessionPresence(boardID:target.id,mode:.board,camera:.init(center:origin.offsetBy(x:200,y:400),scale:1),viewport:.init(x:400,y:800))
    for source in sources {
      let rendered=try await SceneCompositionRenderer(source:source,resources:resources).render(presence:presence,scale:1)
      let pixels=try pixels(rendered.png)
      XCTAssertTrue(dark(pixels,180,150));XCTAssertTrue(dark(pixels,180,285));XCTAssertFalse(dark(pixels,60,70))
    }
    let stored=try XCTUnwrap(store.readSpatialElement(boardID:target.id,elementID:web.id))
    let posed=try XCTUnwrap(store.readElementPlacement(target:target,elementID:web.id,
      groupPoses:["whole":.init(frame:.init(x:80,y:70,width:240,height:600),origin:origin,basis:whole.basis,isGroup:true)]))
    XCTAssertEqual(posed.bounds,shown.bounds.offsetBy(dx:40,dy:40));XCTAssertEqual(posed.origin,origin)
    XCTAssertEqual(try store.readSpatialElement(boardID:target.id,elementID:web.id),stored)
    let fragment=NotebookAttentionSelection.Fragment(target:target,elementID:web.id,region:shown.frame,worldOrigin:origin,pageIndex:nil,label:"Placed source")
    let frozen=NotebookFrozenVisualSources.capture(fragments:[fragment],hierarchy:hierarchy,pages:[:],documents:[:],states:[:],resources:resources).freezingForSubmission()
    let reference=CollaborationReference(id:fragment.id,target:target,elementID:web.id,region:shown.frame,worldOrigin:origin,revision:"mixed-source")
    let pinned=try await NotebookPinnedImageRenderer.render(reference:reference,page:nil,document:nil,state:nil,element:stored,visuals:frozen,resources:resources)
    XCTAssertEqual(pinned.pixelsPerPoint,4.0/3.0,accuracy:0.000001)
    XCTAssertTrue(dark(try pixels(pinned.png),180,150),"Frozen pixels keep the ancestor basis, not the child's untranslated frame")


  }

  func testRotatedLargeSourceCropAndReceiptUseInverseBodyCoordinates() throws {
    let source=AgentElement(id:"large",kind:.web,frame:.init(x:0,y:0,width:5000,height:3000),source:"",html:"<input>")
    let transform=CGAffineTransform(a:0,b:2,c:-3,d:0,tx:0,ty:0)
    let origin=WorldPoint(tileX:1_000_000_000_000,tileY:-1_000_000_000_000,localX:3,localY:7)
    let presence=SessionPresence(boardID:UUID(),mode:.board,camera:.init(center:origin.offsetBy(x:-750,y:1000),scale:1),viewport:.init(x:300,y:400))
    let visible=SceneSourceCapture.visibleRect(source:source,origin:origin,transform:transform,presence:presence)
    XCTAssertEqual(visible,CGRect(x:400,y:200,width:200,height:100))
    let crop=try XCTUnwrap(SceneSourceCapture.region(source:source,origin:origin,transform:transform,presence:presence,density:3))
    XCTAssertTrue(CGRect(x:crop.x,y:crop.y,width:crop.width,height:crop.height).contains(visible))
    let demand=SceneSourceDemand(source:source,minimumScale:3,region:crop,worldOrigin:origin,bodyTransform:transform)
    let receipt=SceneSourceReceipt(demand:demand,installedSource:source,installedScale:3,status:.ready,installedRegion:crop)
    XCTAssertTrue(receipt.coversVisibleWindow(in:presence,pixelDensity:1,refinesDetails:true))
    XCTAssertFalse(receipt.coversVisibleWindow(in:presence,pixelDensity:1.1,refinesDetails:true))
    var moved=demand;moved.worldOrigin=origin.offsetBy(x:100,y:200)
    XCTAssertEqual(moved,demand,"Placement does not restart source pixels or the program")
    let movedReceipt=SceneSourceReceipt(demand:moved,installedSource:source,installedScale:3,status:.ready,installedRegion:crop)
    XCTAssertFalse(movedReceipt.coversVisibleWindow(in:presence,pixelDensity:1,refinesDetails:true))
  }

  func testBoardIndexAndBothCompositorsUseTheWholeTiledOrigin() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-board-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    let header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let target=CollaborationTarget(kind:.board,id:header.rootBoardID)
    let origin=WorldPoint(tileX:1_000_000_000_000,tileY:-1_000_000_000_000,localX:3,localY:7)
    let basis=NotebookElementBasis(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))
    let operations: [CollaborationOperation] = [
      .init(kind:.insertElement,target:target,id:"whole",values:["kind":.string("group"),"source":.string(""),
        "frame":try .encode(PageRect(x:40,y:30,width:240,height:600)),"worldOrigin":try .encode(origin),"basis":try .encode(basis)]),
      .init(kind:.insertElement,target:target,id:"shape",values:["kind":.string("graphic"),"source":.string(""),
        "frame":try .encode(PageRect(x:10,y:20,width:100,height:60)),"worldOrigin":try .encode(WorldPoint.zero),
        "parentID":.string("whole"),"graphic":try .encode(NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:8,fill:.black)))])]
    _ = try store.applyNativeElementEdits(operations,summary:"Вложенная фигура",sources:operations.map { .init(target:target,id:$0.id!) },actor:actor)
    let workspace=try store.loadIndex(),hierarchy=try store.loadBoard(items:workspace.items)
    let index=WorkspaceSceneIndex(workspace:workspace,hierarchy:hierarchy,paperSizes:[:])
    XCTAssertNil(index.paintEntry(id:.element("whole"),boardID:target.id))
    XCTAssertEqual(index.element(id:"whole",boardID:target.id)?.kind,.group,"A descriptor is addressable without becoming painted")
    let entry=try XCTUnwrap(index.paintEntry(id:.element("shape"),boardID:target.id))
    XCTAssertEqual(entry.bounds.origin,origin.offsetBy(x:120,y:60))
    XCTAssertEqual(entry.bounds.width,120);XCTAssertEqual(entry.bounds.height,300)
    let current=try store.workspaceHeader()
    let sources=[SceneCompositionSource(store:store,revision:current.cursor,workspaceID:current.workspaceID),
      SceneCompositionSource(index:index,hierarchy:hierarchy,journal:.init(stamp:workspace.stamp))]
    let presence=SessionPresence(boardID:target.id,mode:.board,
      camera:.init(center:origin.offsetBy(x:200,y:400),scale:1),viewport:.init(x:400,y:800))
    for (offset,source) in sources.enumerated() {
      let result=try await SceneCompositionRenderer(source:source,resources:SceneRenderResources()).render(presence:presence,scale:1)
      let body=try pixels(result.png)
      XCTAssertTrue(dark(body,180,150));XCTAssertTrue(dark(body,180,285))
      XCTAssertFalse(dark(body,60,70),"The unplaced local frame is not another painted copy")
      let proof=XCTAttachment(data:result.png,uniformTypeIdentifier:"public.png")
      proof.name="group-board-\(offset == 0 ? "sql" : "memory")";proof.lifetime = .keepAlways;add(proof)
    }
  }

  func testUncommittedWholePoseMovesPassiveTilesWithoutMovingStoredChildren() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-tile-pose-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID(),header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let target=CollaborationTarget(kind:.board,id:header.rootBoardID),origin=WorldPoint(tileX:1_000_000_000_000,tileY:-1_000_000_000_000,localX:3,localY:7)
    let basis=NotebookElementBasis(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))
    var operations:[CollaborationOperation]=[
      .init(kind:.insertElement,target:target,id:"whole",values:["kind":.string("group"),"source":.string(""),"frame":try .encode(PageRect(x:40,y:30,width:240,height:600)),"worldOrigin":try .encode(origin),"basis":try .encode(basis)]),
      .init(kind:.insertElement,target:target,id:"shape",values:["kind":.string("graphic"),"source":.string(""),"frame":try .encode(PageRect(x:10,y:20,width:100,height:60)),"worldOrigin":try .encode(WorldPoint.zero),"parentID":.string("whole"),
        "graphic":try .encode(NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:8,fill:.black)))])]
    for (id,x) in [("old-neighbor",160.0),("unaffected",15_000)] {
      operations.append(.init(kind:.insertElement,target:target,id:id,values:["kind":.string("graphic"),"source":.string(""),
        "frame":try .encode(PageRect(x:x,y:x,width:10,height:10)),"worldOrigin":try .encode(origin),
        "graphic":try .encode(NotebookGraphic(shape:.rectangle,style:.init(fill:.black)))]))
    }
    _ = try store.applyNativeElementEdits(operations,summary:"Целое",sources:operations.map { .init(target:target,id:$0.id!) },actor:actor)
    let current=try store.workspaceHeader(),whole=try XCTUnwrap(store.readSpatialElement(boardID:target.id,elementID:"whole"))
    let child=try store.readSpatialElement(boardID:target.id,elementID:"shape")
    let pose=NotebookElementPlacement.Source(frame:.init(x:4040,y:4030,width:240,height:600),origin:origin,basis:basis,isGroup:true)
    let projected=SceneCompositionSource(store:store,revision:current.cursor,workspaceID:current.workspaceID,groupPoses:[.board(target.id):["whole":pose]])
    let original=SceneCompositionSource(store:store,revision:current.cursor,workspaceID:current.workspaceID)
    let presence=SessionPresence(boardID:target.id,mode:.board,camera:.init(center:origin.offsetBy(x:4200,y:4400),scale:1),viewport:.init(x:400,y:800))
    func key(_ point:WorldPoint) throws -> SceneCompositionTileKey {
      .init(workspaceID:current.workspaceID,revision:current.cursor,plane:.board(target.id),tile:try XCTUnwrap(CompositionTile(containing:point,level:0)),
        range:.whole(.elements),presentationScale:1,viewportWidth:400,viewportHeight:800,focusedItemID:nil,mode:"board")
    }
    let old=try key(origin.offsetBy(x:180,y:150)),new=try key(origin.offsetBy(x:4180,y:4150)),far=try key(origin.offsetBy(x:15005,y:15005))
    let oldTiles=try await original.tilesRequiringPaint([old,new,far]),newTiles=try await projected.tilesRequiringPaint([old,new,far])
    XCTAssertEqual(oldTiles.map(\.tile),[old.tile,far.tile]);XCTAssertEqual(newTiles.map(\.tile),[old.tile,new.tile,far.tile])
    XCTAssertNotEqual(oldTiles.first?.pixelIdentity,newTiles.first?.pixelIdentity,"The old area must remove the departed whole even though another figure still occupies the tile")
    XCTAssertEqual(oldTiles.last?.pixelIdentity,newTiles.last?.pixelIdentity,"An unrelated populated tile keeps its existing pixels")
    let resources=SceneRenderResources()
    let before=try await SceneCompositionRenderer(source:projected,resources:resources).render(presence:presence,scale:1)
    let shown=try pixels(before.png);XCTAssertTrue(dark(shown,180,150));XCTAssertTrue(dark(shown,180,285))
    let raster=try await SceneCompositionRenderer(source:projected,resources:resources).renderTile(key:try XCTUnwrap(newTiles.first { $0.tile == new.tile }),presentation:presence)
    defer { raster.release() }
    func rgba(_ lease:RasterLease) throws -> Data {
      let image=try XCTUnwrap(lease.sampledImage(for:.init(width:512,height:512)))
      let context=try XCTUnwrap(CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image,in:.init(x:0,y:0,width:image.width,height:image.height))
      return Data(bytes:try XCTUnwrap(context.data),count:image.width*image.height*4)
    }
    let previewPixels=try rgba(raster)
    let workspace=try store.loadIndex(),hierarchy=try store.loadBoard(items:workspace.items)
    let index=WorkspaceSceneIndex(workspace:workspace,hierarchy:hierarchy,paperSizes:[:])
    let frame=WorkspaceSceneFrame(index:index,presence:presence,portalCamera:{ _ in nil },pinned:[])
    let tiles=SceneCompositionTiles(resources:resources)
    defer { tiles.cancelPreparation() }
    func publish(_ source:SceneCompositionSource) async throws -> SceneCompositionCohort {
      tiles.prepare(source:source,presence:presence,frame:frame,pinned:[],displayScale:1)
      let deadline=ContinuousClock.now + .seconds(5)
      while tiles.isPreparing,ContinuousClock.now<deadline { try await Task.sleep(for:.milliseconds(5)) }
      XCTAssertNil(tiles.failure);XCTAssertFalse(tiles.isPreparing)
      return try XCTUnwrap(tiles.published)
    }
    let oldCut=try await publish(original),newCut=try await publish(projected)
    XCTAssertEqual(newCut.plan.groupPoses,[.board(target.id):["whole":pose]])
    XCTAssertNotEqual(oldCut.geometryID,newCut.geometryID,"A pose-only source cut must not reuse the previous live geometry identity")
    XCTAssertTrue(newCut.plan.presentedOwners.isEmpty,"No member is promoted merely to move the whole")
    XCTAssertFalse(newCut.rasters.isEmpty,"The moved group enters the ordinary passive tile coverage")
    let restoredCut=try await publish(original)
    XCTAssertTrue(restoredCut.plan.groupPoses.isEmpty)
    XCTAssertNotEqual(restoredCut.geometryID,newCut.geometryID)
    await tiles.stop()
    XCTAssertTrue(stride(from:3,to:previewPixels.count,by:4).contains { previewPixels[$0]>200 })
    XCTAssertEqual(try store.currentChangeCursor(),current.cursor)
    XCTAssertEqual(try store.readSpatialElement(boardID:target.id,elementID:"whole"),whole)
    XCTAssertEqual(try store.readSpatialElement(boardID:target.id,elementID:"shape"),child)
    _ = try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:"whole",values:["frame":try .encode(pose.frame)])],
      summary:"Переместить целое",sources:[.init(target:target,id:"whole",spatial:whole)],actor:actor)
    let saved=try store.workspaceHeader(),committed=SceneCompositionSource(store:store,revision:saved.cursor,workspaceID:saved.workspaceID)
    let after=try await SceneCompositionRenderer(source:committed,resources:resources).render(presence:presence,scale:1)
    XCTAssertEqual(try pixels(after.png),shown,"The immutable preview uses the same geometry as the accepted pose")
    let savedRaster=try await SceneCompositionRenderer(source:committed,resources:resources).renderTile(key:new.atRevision(saved.cursor),presentation:presence)
    defer { savedRaster.release() }
    XCTAssertEqual(try rgba(savedRaster),previewPixels,"Passive tile pixels agree before and after the one-descriptor commit")
    XCTAssertEqual(try store.readSpatialElement(boardID:target.id,elementID:"shape"),child)
    let proof=XCTAttachment(data:before.png,uniformTypeIdentifier:"public.png");proof.name="group-uncommitted-passive-pose";proof.lifetime = .keepAlways;add(proof)
  }

  func testMaskCacheKeepsWholeTranslationButNotANewLocalBasis() throws {
    let graphic = NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:8))
    func input(_ transform: NotebookGraphicTransform,x: Double) throws -> NotebookElementErasureCache.Input {
      let page = PageDocument(size:.init(width:600,height:600),actor:UUID(),elements:[
        .init(id:"shape",kind:.graphic,frame:.init(x:x,y:40,width:200,height:200),source:"",html:"",graphic:graphic,
          basis:.init(size:.init(x:100,y:100),transform:transform))])
      let layout = try XCTUnwrap(page.graphicGraph().resolve("shape").layout)
      return .init(graphic:graphic,layout:layout,size:.init(width:200,height:200),erasures:[])
    }
    let rotation = NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let first = try input(rotation,x:40), translated = try input(rotation,x:200)
    XCTAssertEqual(first,translated)
    XCTAssertNotNil(first.layout?.projection)
    let reflection = try input(.init(a:-1,b:0,c:0,d:1,tx:1,ty:0),x:40)
    XCTAssertNotEqual(first,reflection,"Same size is not the same rotated mask")
  }

  func testCoverWholePoseInvalidatesItsContainingBoardTile() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("cover-pose-key-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID(),header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let item=try XCTUnwrap(store.loadIndex().selectedItemID),target=CollaborationTarget(kind:.cover,id:item,boardID:header.rootBoardID)
    let basis=NotebookElementBasis(size:.init(x:100,y:100))
    let operations:[CollaborationOperation]=[
      .init(kind:.insertElement,target:target,id:"whole",values:["kind":.string("group"),"source":.string(""),"frame":try .encode(PageRect(x:100,y:100,width:100,height:100)),"basis":try .encode(basis)]),
      .init(kind:.insertElement,target:target,id:"child",values:["kind":.string("graphic"),"source":.string(""),"frame":try .encode(PageRect(x:0,y:0,width:50,height:50)),"parentID":.string("whole"),"graphic":try .encode(NotebookGraphic(shape:.rectangle,style:.init(fill:.black)))])]
    _ = try store.applyNativeElementEdits(operations,summary:"Целое на обложке",sources:operations.map { .init(target:target,id:$0.id!) },actor:actor)
    let cut=try store.workspaceHeader()
    let original=SceneCompositionSource(store:store,revision:cut.cursor,workspaceID:cut.workspaceID)
    let posed=SceneCompositionSource(store:store,revision:cut.cursor,workspaceID:cut.workspaceID,groupPoses:[.cover(boardID:header.rootBoardID,itemID:item):[
      "whole":.init(frame:.init(x:300,y:100,width:100,height:100),basis:basis,isGroup:true)]])
    let key=SceneCompositionTileKey(workspaceID:cut.workspaceID,revision:cut.cursor,plane:.board(header.rootBoardID),
      tile:try XCTUnwrap(CompositionTile(containing:.zero,level:0)),range:.whole(.covers),presentationScale:1,
      viewportWidth:834,viewportHeight:1194,focusedItemID:nil,mode:"board")
    let before=try await original.tilesRequiringPaint([key]),after=try await posed.tilesRequiringPaint([key])
    XCTAssertEqual(before.count,1);XCTAssertEqual(after.count,1)
    XCTAssertNotEqual(before.first?.pixelIdentity,after.first?.pixelIdentity,
      "The containing board must not reuse old cover pixels merely because the board itself has no posed groups")
  }

  func testNativeTextEraserCapturesFullLocalBodyAndFollowsTheWholeInExport() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-body-eraser-\(UUID())")
    let model=NotebookAppModel(store:NotebookStore(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:.init(width:400,height:800))
    var page=try XCTUnwrap(model.activePage)
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:40,y:30,width:300,height:700),source:"",html:"",
      basis:.init(size:.init(x:200,y:200),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0)))
    let text=AgentElement(id:"text",kind:.nativeText,frame:.init(x:10,y:20,width:100,height:10),
      source:"Текст внутри целого сохраняет строки и измеренный след ластика",html:"",textStyle:.init(fontSize:20),parentID:"whole")
    XCTAssertTrue(page.replaceElements([whole,text],actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    let ref=EditableElementReference.page(pageID:page.id,elementID:text.id)
    let shown=try XCTUnwrap(model.elementPresentation(ref)),size=shown.bodySize
    let source=try XCTUnwrap(model.pageEraserSource(pageID:page.id))
    let targets=try source.query(bounds:shown.bounds).targets,target=try XCTUnwrap(targets.first)
    XCTAssertEqual(targets.count,1);XCTAssertFalse(target.wholeElement)
    let bounds=CGRect(origin:.zero,size:size).applying(shown.placement.transform)
    XCTAssertEqual(target.frame,.init(x:bounds.minX,y:bounds.minY,width:bounds.width,height:bounds.height))
    XCTAssertGreaterThan(size.height,text.frame.height)
    // A strip crosses glyphs near the end of the local first line. Its points
    // and circular width are captured in the displayed, nonuniformly scaled basis.
    let samples=[5.0,95].map { x -> SpatialInkSample in
      let p=CGPoint(x:x,y:12).applying(shown.placement.transform)
      return .init(point:.init(x:p.x,y:p.y),timeOffset:0,width:12,opacity:1,force:1,azimuth:0,altitude:1)
    }
    let action=PageInkAction(tool:.eraser,samples:samples).erasingElements(targets)
    let drawing=try PageInkDrawing.decode(PageInkDrawing(actions:[action]).dataRepresentation())
    let cuts=try XCTUnwrap(drawing.elementErasures[text.id])
    let input=NotebookElementErasureCache.Input(graphic:nil,layout:nil,size:size,erasures:cuts)
    let appearance=input.prepare(),live=NotebookElementAppearance.measuredErasurePath(cuts,size:size)
    XCTAssertFalse(appearance.contains(.init(x:50,y:12),tolerance:0));XCTAssertTrue(live.contains(.init(x:50,y:12)))
    XCTAssertTrue(appearance.contains(.init(x:50,y:30),tolerance:0));XCTAssertFalse(live.contains(.init(x:50,y:30)))
    let bottom=CGPoint(x:50,y:size.height-2).applying(shown.placement.transform)
    XCTAssertTrue(target.intersects([.init(point:.init(x:bottom.x,y:bottom.y),timeOffset:0,width:2,opacity:1,force:1,azimuth:0,altitude:1)]),
      "Fitted lines below the authored minimum height are eraser targets too")
    func render(_ ink:PageInkDrawing,_ elements:[AgentElement]) async throws -> Data {
      let source=PageDocument(id:page.id,size:page.size,actor:model.actorID,drawingData:try ink.dataRepresentation(),elements:elements)
      return try await PageCompositionRenderer.render(source,elementID:text.id,scale:1) { _ in
        XCTFail("Native text has no WebKit raster owner");throw CocoaError(.featureUnsupported)
      }.png
    }
    let uncut=try await render(.init(),page.elements),cut=try await render(drawing,page.elements)
    XCTAssertNotEqual(try pixels(uncut),try pixels(cut),"The saved measured cut changes the actual exported glyph pixels")
    let undone=try await render(drawing.settingActive(false,for:[action.id],stamp:.init(counter:1,actor:UUID())),page.elements)
    XCTAssertEqual(try pixels(uncut),try pixels(undone))
    let moved=AgentElement(id:whole.id,kind:.group,frame:.init(x:50,y:50,width:300,height:700),source:"",html:"",basis:whole.basis)
    let movedPage=PageDocument(size:page.size,actor:model.actorID,elements:[moved,text])
    let movedPresentation=NotebookElementPresentation(text,placement:try XCTUnwrap(movedPage.graphicGraph().placement(text.id)))
    XCTAssertEqual(NotebookElementErasureCache.Input(graphic:nil,layout:nil,size:movedPresentation.bodySize,erasures:cuts),input,
      "Moving an ancestor keeps the same prepared body mask")
    let movedCut=try await render(drawing,[moved,text])
    for (name,data) in [("before",uncut),("cut",cut),("whole-moved",movedCut)] {
      let proof=XCTAttachment(data:data,uniformTypeIdentifier:"public.png");proof.name="native-text-eraser-\(name)";proof.lifetime = .keepAlways;add(proof)
    }
    XCTAssertEqual(page.elements[1],text);XCTAssertEqual(drawing.actions.first?.samples,InkMeasurements(samples))
  }

  func testMeasuredEraserCapturesTheModelsWholeBasisNotTheLocalFrame() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-eraser-\(UUID())")
    let store = NotebookStore(root:root),actor = UUID(),size = PageSize(width:400,height:800)
    let (workspace,_) = try store.loadOrCreate(actor:actor,pageSize:size)
    let pageID = try XCTUnwrap(workspace.selectedPageID)
    let turn = NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let page = PageDocument(id:pageID,size:size,actor:actor,elements:[
      .init(id:"whole",kind:.group,frame:.init(x:40,y:30,width:240,height:600),source:"",html:"",
        basis:.init(size:.init(x:200,y:120),transform:turn)),
      .init(id:"shape",kind:.graphic,frame:.init(x:10,y:20,width:100,height:60),source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(strokeWidth:8,fill:.black)),parentID:"whole")])
    var admitted = try store.loadPage(pageID)
    admitted.replaceElements(page.elements,actor:actor)
    try store.savePage(admitted)
    let model = NotebookAppModel(store:store,startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:size)
    let source=try XCTUnwrap(model.pageEraserSource(pageID:pageID))
    let targets=try source.query(bounds:.init(x:120,y:60,width:120,height:300)).targets
    XCTAssertEqual(targets.count,1,"The group descriptor is not a painted eraser target")
    let target = try XCTUnwrap(targets.first)
    XCTAssertEqual(target.frame,.init(x:120,y:60,width:120,height:300))
    XCTAssertEqual(target.elementTransform,turn)
    let action = PageInkAction(tool:.eraser,samples:[140.0,220].map {
      .init(point:.init(x:$0,y:150),timeOffset:0,width:16,opacity:1,force:1,azimuth:0,altitude:1)
    }).erasingElements(targets)
    let drawing = try PageInkDrawing.decode(PageInkDrawing(actions:[action]).dataRepresentation())
    let cuts = try XCTUnwrap(drawing.elementErasures["shape"])
    let layout = try XCTUnwrap(model.graphicGraph(page:page).resolve("shape").layout)
    let appearance = NotebookElementAppearance(graphic:page.elements[1].graphic,layout:layout,
      size:.init(width:120,height:300),erasures:cuts)
    let pendingMask=NotebookElementAppearance.measuredErasurePath(cuts,size:.init(width:120,height:300),layout:layout)
    XCTAssertTrue(pendingMask.contains(.init(x:60,y:90)))
    XCTAssertFalse(pendingMask.contains(.init(x:60,y:110)))
    XCTAssertFalse(appearance.contains(.init(x:60,y:90),tolerance:0))
    XCTAssertTrue(appearance.contains(.init(x:60,y:110),tolerance:0))
    let graph=model.graphicGraph(page:page),surface=SurfaceID.page(pageID)
    func binding(_ point: SpatialPoint) -> NotebookGraphicConnection.Binding? {
      graph.binding(at:point,surface:surface,tolerance:0,erasures:drawing.elementErasures) { id,graphic,layout,size,cuts in
        model.elementErasureCache.appearance(surface:surface,id:id,graphic:graphic,layout:layout,size:size,erasures:cuts)
      }
    }
    XCTAssertNil(binding(.init(x:180,y:250)),"An unprepared cut cannot create an old-coordinate attraction")
    let deadline=ContinuousClock.now + .seconds(5)
    while binding(.init(x:180,y:250)) == nil,ContinuousClock.now<deadline { try await Task.sleep(for:.milliseconds(5)) }
    XCTAssertEqual(binding(.init(x:180,y:250))?.elementID,"shape")
    XCTAssertNil(binding(.init(x:180,y:150)),"Binding shares the displayed cut, not the old local mask")
    let result = try await PageCompositionRenderer.render(PageDocument(id:pageID,size:size,actor:actor,
      drawingData:drawing.dataRepresentation(),elements:page.elements),scale:1) { _ in
      XCTFail("A group is not a WebKit document"); throw CocoaError(.featureUnsupported)
    }
    let proof = XCTAttachment(data:result.png,uniformTypeIdentifier:"public.png")
    proof.name="group-new-measured-cut"; proof.lifetime = .keepAlways; add(proof)
  }

  func testWholeBasisTransformsStrokeAndSavedCutInTheNativeExport() async throws {
    let graphic = NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:8,fill:.black))
    let local = PageRect(x:10,y:20,width:100,height:60)
    let elements: [AgentElement] = [
      .init(id:"whole",kind:.group,frame:.init(x:40,y:30,width:240,height:600),source:"",html:"",
        basis:.init(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))),
      .init(id:"shape",kind:.graphic,frame:local,source:"",html:"",graphic:graphic,parentID:"whole")]
    let erase = PageInkAction(tool:.eraser,samples:[30.0,70].map {
      .init(point:.init(x:40,y:$0),timeOffset:0,width:12,opacity:1,force:1,azimuth:0,altitude:1)
    }).erasingElements([.init(elementID:"shape",frame:local)])
    let drawing = try PageInkDrawing(actions:[erase]).dataRepresentation()
    func render(_ drawing: Data) async throws -> [UInt8] {
      let page = PageDocument(size:.init(width:400,height:800),actor:UUID(),drawingData:drawing,elements:elements)
      // Roundtrip the complete source; groups never become flattened paths or pixels.
      let restored = try JSONDecoder().decode(PageDocument.self,from:JSONEncoder().encode(page))
      let result = try await PageCompositionRenderer.render(restored,scale:1) { _ in
        XCTFail("A nonpainting group must not request WebKit"); throw CocoaError(.featureUnsupported)
      }
      let proof = XCTAttachment(data:result.png,uniformTypeIdentifier:"public.png")
      proof.name = drawing.isEmpty ? "group-basis-uncut" : "group-basis-cut"; proof.lifetime = .keepAlways; add(proof)
      return try pixels(result.png)
    }
    let cut = try await render(drawing), uncut = try await render(Data())
    // Local (30,30) -> whole (180,150); (75,30) -> (180,285).
    XCTAssertFalse(dark(cut,180,150)); XCTAssertTrue(dark(uncut,180,150))
    XCTAssertTrue(dark(cut,180,285)); XCTAssertTrue(dark(uncut,180,285))
    XCTAssertFalse(dark(cut,60,70),"The local source frame is not an extra painted copy")
  }

  func testElementSelectionUsesDisplayedBoundsAndDoesNotSelectTheGroupDescriptor() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-lasso-\(UUID())")
    let store=NotebookStore(root:root),actor=UUID(),size=PageSize(width:600,height:400)
    let (workspace,_)=try store.loadOrCreate(actor:actor,pageSize:size)
    let pageID=try XCTUnwrap(workspace.selectedPageID)
    let turn=NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let ink=NotebookFreehand(layers:[.init(color:.black,vertices:[
      .init(x:0.1,y:0.1,opacity:1),.init(x:0.6,y:0.1,opacity:1),.init(x:0.1,y:0.6,opacity:1)])])
    var page=try store.loadPage(pageID)
    page.replaceElements([
      .init(id:"whole",kind:.group,frame:.init(x:100,y:50,width:400,height:200),source:"",html:"",basis:.init(size:.init(x:100,y:100),transform:turn)),
      .init(id:"ellipse",kind:.graphic,frame:.init(x:0,y:0,width:100,height:100),source:"",html:"",graphic:.init(shape:.ellipse,style:.init(fill:.black)),parentID:"whole"),
      .init(id:"ink",kind:.graphic,frame:.init(x:0,y:0,width:100,height:100),source:"",html:"",graphic:.init(shape:.freehand,freehand:ink),parentID:"whole")],actor:actor)
    try store.savePage(page)
    let model=NotebookAppModel(store:store,startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:size)
    let address=NotebookToolAddress(surface:.page(pageID),boardID:nil,worldOrigin:nil,bounds:nil)
    model.selectDrawingTool(.lasso)
    model.drawingToolSettings.lassoMode = .elements
    func lasso(_ min: Double,_ max: Double) {
      let local:[SpatialPoint]=[.init(x:min,y:min),.init(x:max,y:min),.init(x:max,y:max),.init(x:min,y:max)]
      let points:[SpatialPoint]=local.map { point in SpatialPoint(x:500.0-4.0*point.y,y:50.0+2.0*point.x) }
      XCTAssertTrue(model.drawingTools.begin(at:points[0],address:address,screenScale:1))
      for point in points.dropFirst() { model.drawingTools.move(to:point) };model.drawingTools.finish()
    }
    lasso(2,5)
    XCTAssertTrue(model.selectionSession.elements.isEmpty,"Touching a descendant never selects its whole transformed frame")
    lasso(-1,101)
    XCTAssertEqual(Set(model.selectionSession.elements),Set([address.reference("ellipse"),address.reference("ink")]))
    XCTAssertFalse(model.selectionSession.contains(address.reference("whole")),"The group descriptor is not a selectable painted element")
  }

  func testHeldMemberEditsItsOwnBasisAndKeepsItsOriginalBodyThroughSaveAndUndo() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-pose-\(UUID())")
    let store=NotebookStore(root:root),size=PageSize(width:800,height:1000)
    let model=NotebookAppModel(store:store,startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:size)
    let initialized=await model.finishPendingPersistence();XCTAssertTrue(initialized)
    var page=try XCTUnwrap(model.activePage)
    let pageID=page.id,actor=model.actorID
    let graphic=NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:8,fill:.black),cornerRadius:6)
    page.replaceElements([
      .init(id:"whole",kind:.group,frame:.init(x:40,y:30,width:240,height:600),source:"",html:"",
        basis:.init(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))),
      .init(id:"shape",kind:.graphic,frame:.init(x:10,y:20,width:100,height:60),source:"",html:"",graphic:graphic,parentID:"whole")],actor:actor)
    try store.savePage(page);await model.reloadExternalChanges()?.value
    let reference=EditableElementReference.page(pageID:pageID,elementID:"shape")
    func shown() throws -> NotebookGraphicLayout { try XCTUnwrap(model.graphicLayout(reference)) }
    func check(_ f: PageRect,_ expected: PageRect) {
      XCTAssertEqual(f.x,expected.x,accuracy:1e-9);XCTAssertEqual(f.y,expected.y,accuracy:1e-9)
      XCTAssertEqual(f.width,expected.width,accuracy:1e-9);XCTAssertEqual(f.height,expected.height,accuracy:1e-9)
    }
    model.selectElement(reference)
    let before=try shown(),move=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
    model.updateElementManipulation(move,translation:.init(x:20,y:40))
    check(try shown().frame,.init(x:140,y:100,width:120,height:300))
    XCTAssertEqual(try store.loadPage(pageID),page,"Movement samples do not write or flatten the source")
    model.cancelElementManipulation(move);XCTAssertEqual(try shown(),before)
    let movedContact=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
    XCTAssertTrue(model.finishElementManipulation(movedContact,translation:.init(x:20,y:40)))
    let movedSaved=await model.finishPendingPersistence();XCTAssertTrue(movedSaved);await model.reloadExternalChanges()?.value
    let moved=try store.loadPage(pageID)
    XCTAssertNotEqual(moved.elements[1].frame,page.elements[1].frame,model.actionCue ?? "The accepted movement was not stored")
    XCTAssertEqual(moved.elements[0],page.elements[0]);XCTAssertEqual(moved.elements[1].graphic,graphic)
    XCTAssertNil(moved.elements[1].basis);XCTAssertEqual(moved.elements[1].parentID,"whole")
    check(try shown().frame,.init(x:140,y:100,width:120,height:300))
    let resize=try XCTUnwrap(model.beginElementManipulation(reference,kind:.resize(.bottomTrailing)))
    model.updateElementManipulation(resize,translation:.init(x:60,y:-60))
    let preview=try shown();check(preview.frame,.init(x:140,y:100,width:180,height:240))
    XCTAssertEqual(try store.loadPage(pageID),moved)
    XCTAssertTrue(model.finishElementManipulation(resize,translation:.init(x:60,y:-60)))
    XCTAssertEqual(try shown(),preview,"Accepted preview remains at the measured position")
    let resizedSaved=await model.finishPendingPersistence();XCTAssertTrue(resizedSaved);await model.reloadExternalChanges()?.value
    let resized=try NotebookStore(root:root).loadPage(pageID)
    XCTAssertEqual(resized.elements[0],page.elements[0]);XCTAssertEqual(resized.elements[1].graphic,graphic)
    XCTAssertEqual(resized.elements[1].basis?.size,.init(x:100,y:60));XCTAssertEqual(resized.elements[1].parentID,"whole")
    XCTAssertEqual(try shown(),preview,"Saving never re-solves the pointer against a different basis")
    let action=try XCTUnwrap(store.collaborationActions(afterID:nil).first { $0.action.operations.contains { $0.id == "shape" && $0.values["basis"] != nil } })
    model.undoCollaboration(action.id)
    let undone=await model.finishPendingPersistence();XCTAssertTrue(undone);await model.reloadExternalChanges()?.value
    XCTAssertEqual(try store.loadPage(pageID).elements,moved.elements)
    let stale=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
    let source=try store.readPageElement(pageID:pageID,elementID:"whole"),target=CollaborationTarget(kind:.page,id:pageID)
    _ = try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:"whole",values:["frame":try .encode(PageRect(x:80,y:30,width:240,height:600))])],
      summary:"Другой участник переместил основание",sources:[.init(target:target,id:"whole",page:source)],actor:UUID())
    await model.reloadExternalChanges()?.value
    let queued=model.finishElementManipulation(stale,translation:.init(x:20,y:40))
    let staleFinished=await model.finishPendingPersistence();XCTAssertTrue(staleFinished);await model.reloadExternalChanges()?.value
    if queued { XCTAssertNotNil(model.actionCue,"Queued admission is not a durable receipt; the changed parent must reject it") }
    XCTAssertNil(model.retainedGraphicGraph { .page(pageID:pageID,elementID:$0) })
    XCTAssertEqual(try store.loadPage(pageID).elements[1],moved.elements[1],"A late lift cannot adopt another whole's placement")
  }

  func testConnectorEndpointAndBodyDragUseTheSameNestedBasis() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-connector-drag-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:.init(width:800,height:1000))
    let initialized=await model.finishPendingPersistence();XCTAssertTrue(initialized)
    var page=try XCTUnwrap(model.activePage)
    let graphic=NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"shape")),
      end:.init(point:.init(x:170,y:60)),bend:20))
    page.replaceElements([
      .init(id:"whole",kind:.group,frame:.init(x:40,y:30,width:240,height:600),source:"",html:"",
        basis:.init(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))),
      .init(id:"shape",kind:.graphic,frame:.init(x:10,y:20,width:60,height:60),source:"",html:"",graphic:.init(shape:.ellipse),parentID:"whole"),
      .init(id:"arrow",kind:.graphic,frame:.init(x:0,y:0,width:200,height:120),source:"",html:"",graphic:graphic,parentID:"whole")],actor:model.actorID)
    try model.store.savePage(page);await model.reloadExternalChanges()?.value
    let reference=EditableElementReference.page(pageID:page.id,elementID:"arrow")
    func shown() throws -> NotebookGraphicLayout { try XCTUnwrap(model.graphicLayout(reference)) }
    func point(_ p: SpatialPoint,_ layout: NotebookGraphicLayout) -> CGPoint {
      let p=layout.displayedPoint(p);return .init(x:layout.frame.x+p.x,y:layout.frame.y+p.y)
    }
    model.selectElement(reference)
    let before=try shown(),end=point(before.end,before),contact=try XCTUnwrap(model.beginElementManipulation(reference,kind:.endpoint(.end)))
    model.updateElementManipulation(contact,translation:.init(x:20,y:30))
    let preview=try shown(),nextEnd=point(preview.end,preview)
    XCTAssertEqual(nextEnd.x,end.x+20,accuracy:1e-8);XCTAssertEqual(nextEnd.y,end.y+30,accuracy:1e-8)
    XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:20,y:30)))
    let endpointSaved=await model.finishPendingPersistence();XCTAssertTrue(endpointSaved);await model.reloadExternalChanges()?.value
    XCTAssertEqual(try shown(),preview)
    let move=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
    model.updateElementManipulation(move,translation:.init(x:20,y:30))
    let moved=try shown()
    XCTAssertEqual(moved.curves.count,preview.curves.count)
    for (a,b) in zip(preview.curves,moved.curves) {
      for t in [0.0,0.25,0.5,0.75,1.0] {
        let old=point(a.point(at:t),preview),new=point(b.point(at:t),moved)
        XCTAssertEqual(new.x,old.x+20,accuracy:1e-8);XCTAssertEqual(new.y,old.y+30,accuracy:1e-8)
      }
    }
    XCTAssertTrue(model.finishElementManipulation(move,translation:.init(x:20,y:30)))
    let movedSaved=await model.finishPendingPersistence();XCTAssertTrue(movedSaved);await model.reloadExternalChanges()?.value
    let saved=try model.store.loadPage(page.id)
    XCTAssertEqual(saved.elements[0],page.elements[0]);XCTAssertEqual(saved.elements[1],page.elements[1])
    XCTAssertEqual(saved.elements[2].graphic?.connection?.bindings,[])
    XCTAssertEqual(try shown(),moved)
  }

  func testSelectionCreatesAndManipulatesOneWholeWithoutRewritingItsMembers() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-controls-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:.init(width:800,height:1000))
    let initialized=await model.finishPendingPersistence();XCTAssertTrue(initialized)
    var page=try XCTUnwrap(model.activePage)
    page.replaceElements([
      .init(id:"a",kind:.graphic,frame:.init(x:150,y:150,width:100,height:80),source:"",html:"",graphic:.init(shape:.rectangle,style:.init(strokeWidth:6,fill:.black))),
      .init(id:"between",kind:.graphic,frame:.init(x:200,y:170,width:30,height:30),source:"",html:"",graphic:.init(shape:.ellipse)),
      .init(id:"b",kind:.graphic,frame:.init(x:300,y:200,width:80,height:100),source:"",html:"",graphic:.init(shape:.ellipse,style:.init(strokeWidth:4,fill:.black)))],actor:model.actorID)
    try model.store.savePage(page);await model.reloadExternalChanges()?.value
    func ref(_ id:String) -> EditableElementReference { .page(pageID:page.id,elementID:id) }
    func graph() throws -> NotebookGraphicGraph { model.graphicGraph(page:try XCTUnwrap(model.pages[page.id])) }
    let before=try graph(),original=try ["a","b"].map { try XCTUnwrap(before.resolve($0).layout) }
    model.selectElements([ref("a"),ref("b")]);XCTAssertTrue(model.canGroupSelectedElements)
    model.groupSelectedElements()
    let deadline=ContinuousClock.now + .seconds(10)
    while model.selectionSession.element.map({ model.isElementGroup($0) }) != true,ContinuousClock.now<deadline { try await Task.sleep(for:.milliseconds(10)) }
    let whole=try XCTUnwrap(model.selectionSession.element),grouped=try model.store.loadPage(page.id)
    XCTAssertTrue(model.isElementGroup(whole));XCTAssertEqual(model.parentGroup(ref("a")),whole)
    XCTAssertEqual(grouped.elements.filter { $0.kind != .group }.map(\.id),page.elements.map(\.id))
    XCTAssertEqual(try ["a","b"].map { try XCTUnwrap(graph().resolve($0).layout) },original)
    let children=grouped.elements.filter { $0.kind != .group }
    let held=try XCTUnwrap(model.beginElementManipulation(whole,kind:.move))
    let capture=try XCTUnwrap(model.selectionSession.manipulation?.graphicCapture)
    XCTAssertTrue(capture.closedGroup)
    let initialBounds=try XCTUnwrap(capture.graph.groupBounds(whole.elementID))
    // Real model update and both display queries, after contact admission.
    // No leaf is resolved merely to update the whole's controls.
    let clock=ContinuousClock(),start=clock.now
    for step in 0..<100 {
      let delta=SpatialPoint(x:Double(step%31),y:Double(step%41))
      model.updateElementManipulation(held,translation:delta)
      let projection=try graph(),geometry=try XCTUnwrap(model.groupManipulationGeometry(whole))
      XCTAssertTrue(projection.sharesSource(with:capture.graph))
      XCTAssertEqual(projection.projectedPlacementReadCount,0)
      XCTAssertEqual(geometry.bounds,initialBounds.offsetBy(dx:delta.x,dy:delta.y))
    }
    let timing=XCTAttachment(string:"GUI291 model 100 held whole updates + graph + controls: \(start.duration(to:clock.now)); 2 grouped members and 1 unchanged outsider; excludes cold admission and painting")
    timing.name="gui291-held-whole-model-cost";timing.lifetime = .keepAlways;add(timing)
    model.updateElementManipulation(held,translation:.init(x:30,y:40))
    for (id,old) in zip(["a","b"],original) {
      let next=try XCTUnwrap(graph().resolve(id).layout)
      XCTAssertEqual(next.frame.x,old.frame.x+30,accuracy:1e-9);XCTAssertEqual(next.frame.y,old.frame.y+40,accuracy:1e-9)
    }
    XCTAssertEqual(try model.store.loadPage(page.id),grouped,"A held whole does not write any child")
    model.cancelElementManipulation(held)
    XCTAssertNil(model.retainedGraphicGraph(reference:ref))
    XCTAssertEqual(try ["a","b"].map { try XCTUnwrap(graph().resolve($0).layout) },original)
    let move=try XCTUnwrap(model.beginElementManipulation(whole,kind:.move))
    let moveCapture=try XCTUnwrap(model.selectionSession.manipulation?.graphicCapture)
    XCTAssertTrue(model.finishElementManipulation(move,translation:.init(x:30,y:40)))
    let accepted=try graph()
    XCTAssertTrue(accepted.sharesSource(with:moveCapture.graph))
    XCTAssertEqual(accepted.projectedPlacementReadCount,0)
    XCTAssertEqual(model.groupManipulationGeometry(whole)?.bounds,initialBounds.offsetBy(dx:30,dy:40))
    // A following member draft invalidates the closed whole's retained bounds.
    // This is projection-only; removing it before yielding cannot write a child.
    var member=try XCTUnwrap(accepted.source("a"))
    member.frame = .init(x:member.frame.x+300,y:member.frame.y,width:member.frame.width,height:member.frame.height)
    model.elementCommandDrafts[ref("a")] = .init(source:member,graphic:accepted.node("a")?.graphic)
    let expanded=try XCTUnwrap(graph().groupBounds(whole.elementID))
    XCTAssertGreaterThan(expanded.maxX,initialBounds.maxX+30)
    XCTAssertEqual(model.groupManipulationGeometry(whole)?.bounds,expanded)
    model.elementCommandDrafts[ref("a")] = nil
    let moved=await model.finishPendingPersistence();XCTAssertTrue(moved);await model.reloadExternalChanges()?.value
    XCTAssertNil(model.retainedGraphicGraph(reference:ref))
    XCTAssertEqual(try model.store.loadPage(page.id).elements.filter { $0.kind != .group },children)
    for id in ["a","b"] { XCTAssertEqual(try graph().resolve(id).layout,accepted.resolve(id).layout) }
    let resize=try XCTUnwrap(model.beginElementManipulation(whole,kind:.resize(.bottomTrailing)))
    model.updateElementManipulation(resize,translation:.init(x:40,y:30));let resized=try graph()
    XCTAssertTrue(model.finishElementManipulation(resize,translation:.init(x:40,y:30)))
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved);await model.reloadExternalChanges()?.value
    XCTAssertEqual(try model.store.loadPage(page.id).elements.filter { $0.kind != .group },children)
    for id in ["a","b"] { XCTAssertEqual(try graph().resolve(id).layout,resized.resolve(id).layout) }
    model.transformGraphicSelection(radians:.pi/2)
    let rotated=try graph()
    let rotationSaved=await model.finishPendingPersistence();XCTAssertTrue(rotationSaved);await model.reloadExternalChanges()?.value
    let reopened=try NotebookStore(root:root).loadPage(page.id)
    XCTAssertEqual(reopened.elements.filter { $0.kind != .group },children)
    for id in ["a","b"] { XCTAssertEqual(reopened.graphicGraph().resolve(id).layout,rotated.resolve(id).layout) }
    let actions=try model.store.collaborationActions(afterID:nil)
    let rotation=try XCTUnwrap(actions.first { $0.action.summary == "Повернуть группу" })
    XCTAssertEqual(rotation.action.operations.count,1)
    model.undoCollaboration(rotation.id)
    let undone=await model.finishPendingPersistence();XCTAssertTrue(undone);await model.reloadExternalChanges()?.value
    for id in ["a","b"] { XCTAssertEqual(try graph().resolve(id).layout,resized.resolve(id).layout) }
    let export=try await PageCompositionRenderer.render(reopened,scale:1) { _ in
      XCTFail("The group has no document surface");throw CocoaError(.featureUnsupported)
    }
    let proof=XCTAttachment(data:export.png,uniformTypeIdentifier:"public.png");proof.name="group-controls-saved-export";proof.lifetime = .keepAlways;add(proof)
  }

  func testHeldBoardWholePublishesLiveAndPassiveMembersAtOnePose() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("held-board-whole-\(UUID())")
    let store=NotebookStore(root:root),actor=UUID(),header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let target=CollaborationTarget(kind:.board,id:header.rootBoardID),origin=WorldPoint(x:5000,y:5000)
    let whole=CollaborationOperation(kind:.insertElement,target:target,id:"whole",values:["kind":.string("group"),"source":.string(""),"worldOrigin":try .encode(origin),
      "frame":try .encode(PageRect(x:0,y:0,width:1000,height:700)),"basis":try .encode(NotebookElementBasis(size:.init(x:1000,y:700)))])
    _ = try store.applyNativeElementEdits([whole],summary:"Целое",sources:[.init(target:target,id:"whole")],actor:actor)
    for start in stride(from:0,to:160,by:32) {
      let operations=try (start..<start+32).map { i in
        var values:[String:JSONValue] = ["kind":.string(i<2 ? "nativeText" : "graphic"),"source":.string(i<2 ? "Текст" : ""),"worldOrigin":try .encode(WorldPoint.zero),
          "parentID":.string("whole"),"frame":try .encode(PageRect(x:i == 159 ? 2000 : Double(i%16)*50,y:i == 159 ? 1500 : Double(i/16)*50,width:30,height:30))]
        if i>=2 { values["graphic"] = try .encode(NotebookGraphic(shape:.rectangle,style:.init(fill:.black))) }
        return CollaborationOperation(kind:.insertElement,target:target,id:"shape-\(i)",values:values)
      }
      _ = try store.applyNativeElementEdits(operations,summary:"Участники",sources:operations.map { .init(target:target,id:$0.id!) },actor:actor)
    }
    let child=try store.readSpatialElement(boardID:target.id,elementID:"shape-159")
    let model=NotebookAppModel(store:store,startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:.init(width:834,height:1194))
    let presence=SessionPresence(boardID:target.id,mode:.board,camera:.init(center:origin.offsetBy(x:400,y:300),scale:1),viewport:.init(x:1000,y:800))
      .selecting(itemID:try XCTUnwrap(model.presence?.selectedItemID),pageID:model.presence?.notebookPageID)
    model.updatePresence(presence,settled:true)
    let initialized=await model.finishPendingPersistence();XCTAssertTrue(initialized)
    await model.reloadExternalChanges()?.value
    let ref=EditableElementReference.spatial(boardID:target.id,elementID:"whole"),pins:Set<WorkspaceSpatialID>=[.element("whole")]
    model.selectElement(ref)
    func publish(_ phase:String) async throws -> SceneCompositionCohort {
      let deadline=ContinuousClock.now + .seconds(10)
      repeat {
        let frame=model.sceneIndex.map { WorkspaceSceneFrame(index:$0,presence:presence,portalCamera:model.scenePortalCamera,pinned:pins) }
        model.prepareComposition(presence:presence,frame:frame,pinned:pins,displayScale:1)
        if let cohort=model.compositionTiles.published,cohort.plan.groupPoses == model.compositionGroupPoses,
          cohort.plan.revision == model.workspaceHeader?.cursor,!model.compositionTiles.isPreparing,
          model.spatialGroupReads[target.id]?["whole"] != nil { return cohort }
        try await Task.sleep(for:.milliseconds(10))
      } while ContinuousClock.now<deadline
      XCTFail("\(phase): \(model.compositionTiles.failure ?? model.persistenceFailure ?? "Whole publication timed out"); group=\(model.spatialGroupReads[target.id]?["whole"] != nil), preparing=\(model.compositionTiles.isPreparing), permits=\(model.permitsScenePreparation), revision=\(String(describing:model.compositionTiles.published?.plan.revision))/\(String(describing:model.workspaceHeader?.cursor))")
      return try XCTUnwrap(model.compositionTiles.published)
    }
    let original=try await publish("initial")
    let read=try XCTUnwrap(model.spatialGroupReads[target.id]?["whole"])
    XCTAssertEqual(read.localBounds.width,2030);XCTAssertEqual(read.localBounds.height,1530)
    let start=model.presentedGraphicGraph(boardID:target.id,cohort:original)
    XCTAssertLessThan(start.nodes.count,160,"The contact does not admit all member bodies")
    XCTAssertGreaterThan(original.plan.presentedOwners.count,0);XCTAssertLessThan(original.plan.presentedOwners.count,160)
    XCTAssertFalse(original.rasters.isEmpty,"Some visible members remain in passive tiles")
    let native=try XCTUnwrap(start.placement("shape-0")),nativeSource=try XCTUnwrap(store.readSpatialElement(boardID:target.id,elementID:"shape-0"))
    let nativeBefore=NotebookElementPresentation(nativeSource,placement:native)
    let live=try XCTUnwrap(original.plan.presentedOwners.compactMap { owner -> String? in
      if case .element(let id)=owner.id,start.nodes[id] != nil { return id };return nil
    }.first)
    let before=try XCTUnwrap(start.resolve(live).layout)
    let contact=try XCTUnwrap(model.beginElementManipulation(ref,kind:.move))
    defer { model.cancelElementManipulation() }
    model.updateElementManipulation(contact,translation:.init(x:40,y:25))
    XCTAssertTrue(model.permitsScenePreparation,"A held whole uses the ordinary publisher without waiting for lift")
    XCTAssertEqual(model.presentedGraphicGraph(boardID:target.id,cohort:original).resolve(live).layout,before,
      "The live member must wait for the same publication as passive peers")
    let moved=try await publish("held"),movedGraph=model.presentedGraphicGraph(boardID:target.id,cohort:moved)
    let after=try XCTUnwrap(movedGraph.resolve(live).layout)
    let nativeAfter=NotebookElementPresentation(nativeSource,placement:try XCTUnwrap(movedGraph.placement("shape-0")))
    XCTAssertEqual(nativeAfter.bodySize,nativeBefore.bodySize)
    XCTAssertEqual(nativeAfter.bounds,nativeBefore.bounds.offsetBy(dx:40,dy:25),"Native members share the published whole pose with passive figures")
    XCTAssertEqual(after.frame.x,before.frame.x+40,accuracy:1e-9);XCTAssertEqual(after.frame.y,before.frame.y+25,accuracy:1e-9)
    XCTAssertEqual(model.groupManipulationGeometry(ref)?.bounds,read.localBounds.applying(try XCTUnwrap(movedGraph.placement("whole")).transform))
    XCTAssertNotEqual(moved.geometryID,original.geometryID)
    model.cancelElementManipulation(contact)
    XCTAssertEqual(model.presentedGraphicGraph(boardID:target.id,cohort:moved).resolve(live).layout,after,
      "Cancellation does not snap live bodies back ahead of old tiles")
    let restored=try await publish("cancelled")
    XCTAssertEqual(model.presentedGraphicGraph(boardID:target.id,cohort:restored).resolve(live).layout,before)
    let accepted=try XCTUnwrap(model.beginElementManipulation(ref,kind:.move))
    XCTAssertTrue(model.finishElementManipulation(accepted,translation:.init(x:100,y:50)))
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved,model.persistenceFailure ?? "")
    await model.reloadExternalChanges()?.value
    let committed=try await publish("saved"),shown=model.presentedGraphicGraph(boardID:target.id,cohort:committed)
    XCTAssertTrue(committed.plan.groupPoses.isEmpty)
    let persisted=try XCTUnwrap(store.readGraphicResolution(target:target,elementID:live).layout)
    XCTAssertEqual(shown.resolve(live).layout,persisted)
    XCTAssertEqual(persisted.frame.x,before.frame.x+100,accuracy:1e-9);XCTAssertEqual(persisted.frame.y,before.frame.y+50,accuracy:1e-9)
    XCTAssertEqual(try store.readSpatialElement(boardID:target.id,elementID:"shape-159"),child)
    XCTAssertEqual(model.presence?.camera,presence.camera)
    let image=try await SceneCompositionRenderer(source:SceneCompositionSource(store:store,revision:committed.plan.revision,workspaceID:committed.plan.workspaceID),resources:SceneRenderResources()).render(presence:presence,scale:1)
    let proof=XCTAttachment(data:image.png,uniformTypeIdentifier:"public.png");proof.name="held-board-whole-saved";proof.lifetime = .keepAlways;add(proof)
  }

  func testBoardBasisWaitsForItsPublicationAndDoesNotMixMembershipCuts() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-cohort-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:.init(width:800,height:1000))
    let initialized=await model.finishPendingPersistence();XCTAssertTrue(initialized)
    let boardID=try XCTUnwrap(model.workspace?.rootBoardID),target=CollaborationTarget(kind:.board,id:boardID),group=UUID().uuidString
    let operations:[CollaborationOperation]=[
      .init(kind:.insertElement,target:target,id:group,values:["kind":.string("group"),"source":.string(""),"worldOrigin":try .encode(WorldPoint.zero),
        "frame":try .encode(PageRect(x:40,y:50,width:200,height:100)),"basis":try .encode(NotebookElementBasis(size:.init(x:200,y:100)))]),
      .init(kind:.insertElement,target:target,id:"a",values:["kind":.string("graphic"),"source":.string(""),"worldOrigin":try .encode(WorldPoint.zero),
        "frame":try .encode(PageRect(x:10,y:10,width:60,height:50)),"parentID":.string(group.lowercased()),"graphic":try .encode(NotebookGraphic(shape:.rectangle))]),
      .init(kind:.insertElement,target:target,id:"b",values:["kind":.string("graphic"),"source":.string(""),"worldOrigin":try .encode(WorldPoint.zero),
        "frame":try .encode(PageRect(x:100,y:20,width:70,height:50)),"parentID":.string(group),"graphic":try .encode(NotebookGraphic(shape:.ellipse))])]
    _ = try model.store.applyNativeElementEdits(operations,summary:"Группа на доске",sources:operations.map { .init(target:target,id:$0.id!) },actor:model.actorID)
    await model.reloadExternalChanges()?.value
    let workspace=try XCTUnwrap(model.workspace),hierarchy=try XCTUnwrap(model.boardHierarchy),captured=try XCTUnwrap(hierarchy.board(boardID))
    let index=WorkspaceSceneIndex(workspace:workspace,hierarchy:hierarchy,paperSizes:[:])
    let presence=SessionPresence(boardID:boardID,mode:.board,camera:.init(),viewport:.init(x:800,y:600))
    let frame=WorkspaceSceneFrame(index:index,presence:presence,portalCamera:{ _ in nil })
    func cohort(_ live:[String]) -> SceneCompositionCohort {
      let owners=live.enumerated().map { i,id in SceneCompositionLiveOwner(plane:.board(boardID),id:.element(id),position:.init(layer:.elements,zIndex:Double(i),key:id)) }
      let plan=SceneCompositionPlan(revision:1,workspaceID:index.generationID,rootBoardID:boardID,inkBoardIDs:[],liveOwners:owners,protectedOwners:[],
        bands:[],coverage:[:],presentations:[.board(boardID):presence],tiles:[])
      let data=SceneCompositionLiveData(documents:[:],states:[:],pages:[:],ink:.init(stamp:workspace.stamp))
      #if os(iOS)
      return .init(plan:plan,frame:frame,requestedSources:frame.sourceIdentity,liveData:data,rasters:[:],liveRasters:[:],
        nativeInk:.init(registry:.init(),rootBoardID:boardID,focusedCoverID:nil,owners:[:],updates:[]))
      #else
      return .init(plan:plan,frame:frame,liveData:data,rasters:[:],liveRasters:[:])
      #endif
    }
    let source=try model.store.readSpatialElement(boardID:boardID,elementID:group)
    _ = try model.store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:group,values:["frame":try .encode(PageRect(x:130,y:70,width:200,height:100))])],
      summary:"Переместить общее основание",sources:[.init(target:target,id:group,spatial:source)],actor:model.actorID)
    await model.reloadExternalChanges()?.value
    let old=captured.graphicGraph(),all=cohort(["a","b"]),partial=cohort(["a"])
    for id in ["a","b"] {
      let before=try XCTUnwrap(old.resolve(id).layout)
      let moved=try XCTUnwrap(model.presentedGraphicGraph(boardID:boardID,cohort:all).resolve(id).layout)
      XCTAssertEqual(moved,before,"All admitted bodies being live does not prove there are no passive members outside that bounded read")
      XCTAssertEqual(model.presentedGraphicGraph(boardID:boardID,cohort:partial).resolve(id).layout,before,
        "One live member must not move ahead of the same whole's retained passive pixels")
    }
    let beforeRegroup=model.presentedGraphicGraph(boardID:boardID,cohort:all)
    _ = try model.store.groupNativeElements(["a","b"].map { try .init(target:target,id:$0,spatial:model.store.readSpatialElement(boardID:boardID,elementID:$0)) },id:"nested",actor:model.actorID)
    await model.reloadExternalChanges()?.value
    let retained=model.presentedBoard(captured,boardID:boardID,cohort:all)
    XCTAssertEqual(retained.elements.first { $0.id == "a" }?.parentID,group.lowercased())
    for id in ["a","b"] { XCTAssertEqual(model.presentedGraphicGraph(boardID:boardID,cohort:all).resolve(id).layout,beforeRegroup.resolve(id).layout) }
  }

  func testPageViewportSkipsHiddenMembersAndKeepsTheSameVisiblePixelsDuringAWholeDrag() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-visible-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:.init(width:1000,height:1000))
    let initialized=await model.finishPendingPersistence();XCTAssertTrue(initialized)
    var page=try XCTUnwrap(model.activePage)
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:20,y:20,width:900,height:900),source:"",html:"",basis:.init(size:.init(x:900,y:900)))
    var children=(0..<1000).map { i in AgentElement(id:"part-\(i)",kind:.graphic,
      frame:.init(x:Double(i%32)*28,y:Double(i/32)*28,width:16,height:16),source:"",html:"",
      graphic:.init(shape:i.isMultiple(of:2) ? .rectangle : .ellipse,style:.init(strokeWidth:1,fill:.black)),parentID:"whole") }
    children.insert(.init(id:"between",kind:.graphic,frame:.init(x:350,y:390,width:30,height:30),source:"",html:"",
      graphic:.init(shape:.ellipse,style:.init(strokeWidth:3,fill:.init(red:1,green:1,blue:1)))),at:501)
    XCTAssertTrue(page.replaceElements([whole]+children,actor:model.actorID))
    try model.store.savePage(page);await model.reloadExternalChanges()?.value
    page=try XCTUnwrap(model.pages[page.id])
    let reference=EditableElementReference.page(pageID:page.id,elementID:"whole")
    model.selectElement(reference)
    let held=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
    model.updateElementManipulation(held,translation:.init(x:40,y:50))
    let area=CGRect(x:340,y:370,width:48,height:48)
    let visible=model.pageGraphicDisplay(page,in:area)
    XCTAssertEqual(visible.elements.count,5)
    XCTAssertLessThan(visible.resolvedGraphics,8);XCTAssertLessThan(visible.visitedIndexNodes,150)
    XCTAssertEqual(visible.elements.map(\.id),page.elements.filter { visible.layouts[$0.id] != nil }.map(\.id))
    func render(_ region:CGRect?) throws -> CGImage {
      let painter=ImageRenderer(content:AgentOverlayView(page:page,renderingScale:1,allowsInteraction:false,inputEnabled:false,
        onRenderReady:{ _ in },onState:{ _,_ in false },visibleRegion:region).environment(model)
        .frame(width:1000,height:1000).background(Color.white))
      painter.scale=1
      return try XCTUnwrap(painter.cgImage)
    }
    func rgba(_ image:CGImage) throws -> Data {
      let clipped=try XCTUnwrap(image.cropping(to:area))
      let context=try XCTUnwrap(CGContext(data:nil,width:clipped.width,height:clipped.height,bitsPerComponent:8,bytesPerRow:clipped.width*4,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(clipped,in:.init(x:0,y:0,width:clipped.width,height:clipped.height))
      return Data(bytes:try XCTUnwrap(context.data),count:clipped.width*clipped.height*4)
    }
    let all=try render(nil),small=try render(area),pixels=try rgba(small)
    XCTAssertEqual(pixels,try rgba(all),"Culling must retain the interleaved painter order and exactly the same crop")
    XCTAssertTrue(stride(from:0,to:pixels.count,by:4).contains { pixels[$0]<80 && pixels[$0+1]<80 && pixels[$0+2]<80 },"An empty image is not a valid comparison")
    let clock=ContinuousClock()
    func ms(_ d:Duration) -> Double { let c=d.components;return Double(c.seconds)*1000+Double(c.attoseconds)/1e15 }
    var full:[Double]=[],bounded:[Double]=[]
    for i in 0..<10 {
      for limited in (i.isMultiple(of:2) ? [false,true] : [true,false]) {
        let start=clock.now,image=try render(limited ? area : nil),elapsed=ms(start.duration(to:clock.now))
        XCTAssertEqual(image.width,1000)
        if limited { bounded.append(elapsed) } else { full.append(elapsed) }
      }
    }
    let record:[String:Any]=["scope":"Debug ImageRenderer, same live AgentOverlayView, warm source/index, 1001 graphics, 48x48 crop; not on-screen FPS or input-to-present",
      "fullPageMs":full,"visibleOnlyMs":bounded,"displayedGraphics":visible.elements.count,
      "resolvedGraphics":visible.resolvedGraphics,"visitedIndexNodes":visible.visitedIndexNodes]
    let timing=XCTAttachment(data:try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    timing.name="gui291-page-visible-render-cost";timing.lifetime = .keepAlways;add(timing)
    let data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,small,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let proof=XCTAttachment(data:data as Data,uniformTypeIdentifier:"public.png");proof.name="group-visible-page-crop";proof.lifetime = .keepAlways;add(proof)
    model.cancelElementManipulation(held)
    XCTAssertEqual(try model.store.loadPage(page.id).elements,page.elements)
  }

  func testNativeCameraChangesTheGraphicCandidatesWithoutRepublishingTheirSource() async throws {
    #if os(iOS)
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first { $0.isKeyWindow },window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil;previous?.makeKey() }
    let clip=UIView(frame:.init(x:30,y:30,width:96,height:96));clip.clipsToBounds=true
    controller.view.addSubview(clip)
    let host=PagePresentationNativeView()
    #else
    let window=NSWindow(contentRect:.init(x:0,y:0,width:96,height:96),styleMask:[.titled],backing:.buffered,defer:false)
    let clip=PagePresentationNativeView(frame:.init(x:0,y:0,width:96,height:96))
    window.contentView=clip;window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil);window.contentView=nil }
    let host=PagePresentationNativeView(frame:.zero)
    #endif
    host.frame = .init(x:-160,y:0,width:400,height:400);clip.addSubview(host)
    let viewport=host.viewport;defer { viewport.stop() }
    let page=PageDocument(size:.init(width:400,height:400),actor:UUID(),elements:[
      .init(id:"a",kind:.graphic,frame:.init(x:180,y:20,width:20,height:20),source:"",html:"",graphic:.init(shape:.rectangle)),
      .init(id:"b",kind:.graphic,frame:.init(x:20,y:20,width:20,height:20),source:"",html:"",graphic:.init(shape:.ellipse))])
    let graph=page.graphicGraph(),projection=ScenePlaneProjection(.init(mode:.page,camera:.init(),viewport:.init(x:96,y:96)))
    viewport.isVisible=true
    func move(_ x:CGFloat,expecting id:String) async {
      let ready=expectation(description:"Native viewport shows \(id)")
      viewport.onRegion={ area in
        XCTAssertTrue(page.graphicGraph().sharesSource(with:graph))
        let candidates=graph.visiblePageGraphics(page.id,in:area)
        if Set(candidates.layouts.keys) == [id] { ready.fulfill() }
      }
      host.frame.origin.x=x;viewport.observe(projection);projection.didProject()
      await fulfillment(of:[ready],timeout:3)
    }
    await move(-160,expecting:"a");await move(0,expecting:"b");await move(-160,expecting:"a")
  }

  private func pixels(_ png: Data) throws -> [UInt8] {
    let source=try XCTUnwrap(CGImageSourceCreateWithData(png as CFData,nil))
    let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
    let context=try XCTUnwrap(CGContext(data:nil,width:400,height:800,bitsPerComponent:8,bytesPerRow:1600,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image,in:.init(x:0,y:0,width:400,height:800))
    return Array(UnsafeBufferPointer(start:try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self),count:400*800*4))
  }
  private func dark(_ pixels: [UInt8],_ x: Int,_ y: Int) -> Bool {
    let p=(y*400+x)*4
    return max(pixels[p],pixels[p+1],pixels[p+2])<80
  }
}

private struct MixedWholeProgramPage: View {
  @Environment(NotebookAppModel.self) private var model
  let pageID:UUID
  var body: some View {
    if let page=model.pages[pageID] {
      AgentOverlayView(page:page,renderingScale:1,allowsInteraction:true,inputEnabled:true,
        onRenderReady:{ _ in },onState:{ _,_ in false })
        .frame(width:page.size.width,height:page.size.height,alignment:.topLeading).background(.white)
    }
  }
}
