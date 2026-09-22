import MetalKit
import NotebookCore
import SwiftUI

/// Live retained vectors and measured cutout masks go directly to a drawable.
/// Export alone uses InkRasterRenderer's explicit CGImage readback. Geometry,
/// connectivity and blending still belong to the same compact ink renderer.
struct NotebookInkMaterialView: View {
  var freehand: NotebookFreehand? = nil
  var erasures: [InkElementErasure] = []
  var transform: NotebookGraphicTransform? = nil
  var layout: NotebookGraphicLayout? = nil
  var mask: NotebookGraphicMask? = nil
  var body: some View { Native(content:.init(freehand:freehand,erasures:erasures,transform:transform,layout:layout,mask:mask)).allowsHitTesting(false) }

  struct Content: Equatable {
    let freehand: NotebookFreehand?
    let erasures: [InkElementErasure]
    let transform: NotebookGraphicTransform?
    let layout: NotebookGraphicLayout?
    let mask: NotebookGraphicMask?
    init(freehand:NotebookFreehand?,erasures:[InkElementErasure],transform:NotebookGraphicTransform?,
      layout:NotebookGraphicLayout?,mask:NotebookGraphicMask? = nil) {
      self.freehand=freehand;self.erasures=erasures;self.transform=transform;self.layout=layout;self.mask=mask
    }
  }
  private struct Native: PlatformViewRepresentable {
    @Environment(\.scenePlaneProjection) private var projection
    @Environment(\.inkMaterialReadiness) private var readiness
    let content: Content
    #if os(iOS)
    func makeUIView(context:Context) -> InkMaterialHost { .init() }
    func updateUIView(_ view:InkMaterialHost,context:Context) { view.update(content,projection:projection,report:readiness) }
    static func dismantleUIView(_ view:InkMaterialHost,coordinator:()) { view.stop() }
    #else
    func makeNSView(context:Context) -> InkMaterialHost { .init() }
    func updateNSView(_ view:InkMaterialHost,context:Context) { view.update(content,projection:projection,report:readiness) }
    static func dismantleNSView(_ view:InkMaterialHost,coordinator:()) { view.stop() }
    #endif
  }
}

#if os(iOS)
private typealias PlatformViewRepresentable = UIViewRepresentable
#else
private typealias PlatformViewRepresentable = NSViewRepresentable
#endif

final class InkMaterialHost: PageInkHost {
  let canvas = InkCanvasView(frame:.zero)
  private let id = UUID()
  private var content: NotebookInkMaterialView.Content?
  private var report: NotebookInkMaterialReceiver?
  lazy var projection = PageInkProjection(host:self,canvas:canvas)
  init() {
    super.init(frame:.zero); addSubview(canvas)
    canvas.onVisibleFrame = { [weak self] in
      self?.setInitialMaskBackground(false);self?.canvas.onVisibleFrame=nil
    }
    canvas.onRenderReadinessChange = { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self,let content=self.content else { return }
        report?.report(id,content,canvas.isStableFramePresented && canvas.window != nil)
      }
    }
  }
  required init?(coder:NSCoder) { fatalError("Use init()") }
  func update(_ content:NotebookInkMaterialView.Content,projection value:ScenePlaneProjection?,report:NotebookInkMaterialReceiver?) {
    let changedReceiver=self.report?.id != report?.id
    if self.content == nil { setInitialMaskBackground(content.freehand == nil) }
    self.content=content;self.report=report
    canvas.updateMaterial(content);projection.observe(value)
    if changedReceiver {
      Task { @MainActor [weak self] in
        guard let self,let content=self.content else { return }
        self.report?.report(id,content,canvas.isStableFramePresented && canvas.window != nil)
      }
    }
  }
  private func setInitialMaskBackground(_ white:Bool) {
    #if os(iOS)
    backgroundColor = white ? .white : .clear
    #else
    wantsLayer=true;layer?.backgroundColor = (white ? NSColor.white : NSColor.clear).cgColor
    #endif
  }
  func stop() {
    let report=report,id=id
    self.report=nil;content=nil
    Task { @MainActor in report?.report(id,nil,false) }
    projection.stop()
    canvas.removeFromSuperview()
    Task { await canvas.finishSpatialHandoffFrames() }
  }
  #if os(iOS)
  override func layoutSubviews() { super.layoutSubviews();projection.refresh() }
  override func didMoveToWindow() { super.didMoveToWindow();projection.refresh() }
  #else
  override var isFlipped:Bool { true }
  override func layout() { super.layout();projection.refresh() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow();projection.refresh() }
  override func hitTest(_ point:NSPoint) -> NSView? { nil }
  #endif
}

@MainActor
final class InkMaterialRenderer {
  private struct Buffer {
    let prepared: NotebookFreehandGeometry.Prepared
    let nodes: any MTLBuffer
    let count: Int
    let level: Int
    let bytes: RasterReservation
  }
  private struct Source {
    let ink: NotebookFreehand
    let target: InkElementTarget?
    let samples: InkMeasurements?
    var buffers: [Range<Int>: Buffer] = [:]
  }
  private var content: NotebookInkMaterialView.Content?
  private var sources: [Source] = []
  private(set) var uploadedNodes = 0
  var isMask: Bool { content?.freehand == nil }

  /// Owns only derived geometry. InkCanvasView owns admission, drawables,
  /// completion/readiness, presentation, and teardown for every live ink path.
  func releaseBuffers() {
    for i in sources.indices { sources[i].buffers.removeAll() }
  }

  @discardableResult
  func update(_ next:NotebookInkMaterialView.Content) -> Bool {
    guard content != next else { return false }
    var updated: [Source] = []
    if let ink=next.freehand {
      let retained=sources.first.flatMap { $0.target == nil && $0.ink == ink ? $0 : nil }
      updated.append(retained ?? Source(ink:ink,target:nil,samples:nil))
    }
    let offset=next.freehand == nil ? 0 : 1
    for (i,cut) in next.erasures.enumerated() {
      let frame=cut.target.frame
      let ink=NotebookFreehand(layers:[.init(tool:.eraser,color:.black,measured:.init(
        sourceID:cut.samples.revision,measurements:cut.samples,frame:frame,origin:cut.target.worldOrigin))])
      var source=Source(ink:ink,target:cut.target,samples:cut.samples)
      if sources.indices.contains(i+offset) {
        let old=sources[i+offset]
        if old.target == cut.target,let previous=old.samples {
          if previous == cut.samples { source=old }
          else {
            let prefix=cut.samples.unchangedPrefix(comparedTo:previous)
            source.buffers=old.buffers.filter { $0.value.prepared.descriptor.range.upperBound+2 < prefix }
          }
        }
      }
      updated.append(source)
    }
    content=next;sources=updated;return true
  }
  /// Maps normalized source coordinates through the captured body and current
  /// whole transform. Erasures retain their authored basis under shear/rotation.
  private func basis(for source:Source, sourceSize:CGSize) -> CGAffineTransform {
    let layout=content?.layout, size=layout?.projection?.size ?? sourceSize
    func point(_ unit:SpatialPoint) -> CGPoint {
      var p=unit
      if let target=source.target {
        p=target.elementTransform?.unapplying(p) ?? p
        p=(target.graphicTransform ?? .identity).unapplying(p)
      }
      p=(content?.transform ?? .identity).applying(p)
      let result=CGPoint(x:p.x*size.width,y:p.y*size.height)
      return layout?.projection.map { result.applying($0.transform) } ?? result
    }
    let a=point(.zero),b=point(.init(x:1,y:0)),c=point(.init(x:0,y:1))
    return .init(a:b.x-a.x,b:b.y-a.y,c:c.x-a.x,d:c.y-a.y,tx:a.x,ty:a.y)
  }
  private func affine(_ basis:CGAffineTransform,unit:CGSize,region:CGRect) -> InkAffine {
    .init(x:.init(Float(basis.a/unit.width),Float(basis.c/unit.height),Float(basis.tx-region.minX),0),
      y:.init(Float(basis.b/unit.width),Float(basis.d/unit.height),Float(basis.ty-region.minY),0))
  }

  static func queryRegion(_ content:NotebookInkMaterialView.Content,region:CGRect,sourceSize:CGSize,density:CGFloat)->CGRect {
    guard let mask=content.mask else { return region }
    let frame=CGRect(origin:.zero,size:sourceSize)
    let visible=mask.conservativeBounds(in:frame,projection:content.layout?.projection)
    guard !visible.isNull,!visible.isEmpty else { return .null }
    return region.intersection(visible.insetBy(dx:-1/density,dy:-1/density))
  }

  func encode(region:CGRect, sourceSize:CGSize, pixels:CGSize,
    device:any MTLDevice, resources:SceneRenderResources, owner:ScenePhysicalOwnerLease?,
    encoder:any MTLRenderCommandEncoder) throws -> [RasterReservation] {
    guard let ink=InkRasterRenderer.shared.ink,let erase=InkRasterRenderer.shared.eraser,
      let connectivity=InkRasterRenderer.shared.connectivity else { throw SceneRenderError.resourceLimit }
    let density=max(pixels.width/region.width,pixels.height/region.height)
    let queryRegion=Self.queryRegion(content!,region:region,sourceSize:sourceSize,density:density)
    guard !queryRegion.isNull,!queryRegion.isEmpty else {
      for i in sources.indices { sources[i].buffers.removeAll() }
      return []
    }
    var viewport=SIMD2<Float>(Float(region.width),Float(region.height))
    encoder.setVertexBytes(&viewport,length:MemoryLayout<SIMD2<Float>>.stride,index:1)
    var held: [RasterReservation] = []
    let grid=InkRasterRenderer.shared.sampleGrid(viewport:region.size,pixels:pixels)
    for i in sources.indices {
      let source=sources[i],geometry=source.ink.geometry,basis=basis(for:source,sourceSize:sourceSize)
      let area=queryRegion.applying(basis.inverted())
      let query=geometry.query(area,allowRangeCoalescing:basis.b == 0 && basis.c == 0,
        detail:{ unit in let a=self.affine(basis,unit:unit,region:region);return .init(pixelsPerUnit:a.maximumStretch*Float(density),minimumPixelsPerUnit:a.minimumStretch*Float(density)) },
        admitting:grid.map { grid in { box,unit in grid.mayCover(box,affine:self.affine(basis,unit:unit,region:region)) } })
      let selected=Set(query.indices)
      sources[i].buffers=sources[i].buffers.filter { selected.contains($0.key) }
      for id in query.indices {
        let prepared=sources[i].buffers[id]?.prepared ?? geometry.prepared(at:id)
        var affine=affine(basis,unit:prepared.descriptor.sourceSize,region:region)
        let level=InkRenderGeometry.level(prepared.geometry.descriptor.levels,
          pixelsPerUnit:affine.maximumStretch*Float(density),minimumPixelsPerUnit:affine.minimumStretch*Float(density))
        if sources[i].buffers[id]?.level != level {
          let nodes=prepared.geometry.selected(level:level)
          guard !nodes.isEmpty,
            let bytes=resources.reserveDerivedBytes(prepared.geometry.byteCount+nodes.count*MemoryLayout<InkRenderGeometry.Node>.stride,priority:.input,owner:owner),
            let buffer=nodes.withUnsafeBytes({ device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }) else { throw SceneRenderError.resourceLimit }
          sources[i].buffers[id] = .init(prepared:prepared,nodes:buffer,count:nodes.count,level:level,bytes:bytes)
          uploadedNodes += nodes.count
        }
        guard let buffer=sources[i].buffers[id] else { continue }
        held.append(buffer.bytes)
        let tool=geometry.tool(at:id),color=geometry.color(at:id)
        encoder.setRenderPipelineState(tool == .eraser ? erase : ink)
        encoder.setVertexBuffer(buffer.nodes,offset:0,index:0)
        encoder.setVertexBytes(&affine,length:MemoryLayout<InkAffine>.stride,index:2)
        var primitive=InkPrimitive(count:UInt32(buffer.count),flags:prepared.descriptor.flags,
          color:.init(Float(color.red),Float(color.green),Float(color.blue),1))
        encoder.setVertexBytes(&primitive,length:MemoryLayout<InkPrimitive>.stride,index:3)
        connectivity.draw(nodes:buffer.count,flags:prepared.descriptor.flags,encoder:encoder)
      }
    }
    return held
  }
}

/// Existing page/cohort owners aggregate exact material sources. A mounted
/// representable or a completed hidden drawable is not a visible-frame receipt.
typealias InkMaterialReadinessReport = @MainActor (UUID,NotebookInkMaterialView.Content?,Bool) -> Void
struct NotebookInkMaterialReceiver {
  let id: UUID
  let report: InkMaterialReadinessReport
}
private struct InkMaterialReadinessKey: EnvironmentKey {
  static let defaultValue: NotebookInkMaterialReceiver? = nil
}
extension EnvironmentValues {
  var inkMaterialReadiness: NotebookInkMaterialReceiver? {
    get { self[InkMaterialReadinessKey.self] }
    set { self[InkMaterialReadinessKey.self] = newValue }
  }
}
struct NotebookInkMaterialReadiness {
  private struct Entry: Equatable { let content:NotebookInkMaterialView.Content;let ready:Bool }
  private var entries: [UUID:Entry] = [:]
  @discardableResult
  mutating func record(_ id:UUID,content:NotebookInkMaterialView.Content?,ready:Bool) -> Bool {
    let next=content.map { Entry(content:$0,ready:ready) }
    guard entries[id] != next else { return false }
    entries[id]=next;return true
  }
  func isReady(for sources:[NotebookInkMaterialView.Content]) -> Bool {
    sources.allSatisfy { source in entries.values.contains { $0.ready && $0.content == source } }
  }
}
extension NotebookInkMaterialView.Content {
  static func required(graphic:NotebookGraphic?,layout:NotebookGraphicLayout?,
    erasures:[InkElementErasure],appearance:NotebookElementAppearance?) -> [Self] {
    guard appearance?.state != .erased,!erasures.contains(where: { $0.target.wholeElement }) else { return [] }
    var result:[Self]=[]
    if let graphic,graphic.showsGeometry,let freehand=graphic.freehand {
      result.append(.init(freehand:freehand,erasures:[],transform:graphic.transform,layout:layout,mask:graphic.mask))
    }
    if !erasures.isEmpty {
      result.append(.init(freehand:nil,erasures:erasures,transform:graphic?.transform,layout:layout))
    }
    return result
  }
}
